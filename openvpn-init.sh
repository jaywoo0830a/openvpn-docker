#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-./compose.yaml}"
DATA_DIR="${DATA_DIR:-./openvpn-as-data}"

AS_ADMIN_PORT="${AS_ADMIN_PORT:-943}"
AS_TCP_PORT="${AS_TCP_PORT:-443}"
AS_UDP_PORT="${AS_UDP_PORT:-1194}"

# Hardening toggles
ENABLE_TCP_443="${ENABLE_TCP_443:-0}"          # 1 to allow TCP 443 (optional)
ALLOW_ADMIN_943_EXTERNALLY="${ALLOW_ADMIN_943_EXTERNALLY:-0}" # must stay 0 (hardening)

ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

RULE_TAG_PREFIX="managed-by=openvpn-as"
RULE_TAG_UDP="${RULE_TAG_PREFIX};udp:${AS_UDP_PORT}"
RULE_TAG_TCP="${RULE_TAG_PREFIX};tcp:${AS_TCP_PORT}"
RULE_TAG_ADMIN="${RULE_TAG_PREFIX};admin:${AS_ADMIN_PORT}"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Please run as root (sudo)."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }
compose() { docker compose -f "${COMPOSE_FILE}" "$@"; }

ensure_prereqs() {
  have_cmd docker || { echo "ERROR: docker not found."; exit 1; }
  docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose plugin not available."; exit 1; }
  have_cmd nft || { echo "ERROR: nft not found. Install: sudo apt-get install -y nftables"; exit 1; }
}

ensure_host_fw_exists() {
  nft list table inet host_fw >/dev/null 2>&1 || { echo "ERROR: nft table 'inet host_fw' not found."; exit 1; }
  nft list chain inet host_fw input >/dev/null 2>&1 || { echo "ERROR: nft chain 'inet host_fw input' not found."; exit 1; }
}

rule_exists_by_comment() {
  local comment="$1"
  nft -a list chain inet host_fw input | grep -F "comment \"${comment}\"" >/dev/null 2>&1
}

add_host_fw_rules() {
  ensure_host_fw_exists

  echo "[init] Adding rules to inet host_fw input (policy drop firewall)."

  # Always allow UDP 1194
  if ! rule_exists_by_comment "${RULE_TAG_UDP}"; then
    nft add rule inet host_fw input udp dport "${AS_UDP_PORT}" ct state new accept comment "\"${RULE_TAG_UDP}\""
  fi

  # Optional TCP 443
  if [[ "${ENABLE_TCP_443}" == "1" ]]; then
    if ! rule_exists_by_comment "${RULE_TAG_TCP}"; then
      nft add rule inet host_fw input tcp dport "${AS_TCP_PORT}" ct state new accept comment "\"${RULE_TAG_TCP}\""
    fi
  else
    echo "[init] TCP 443 is disabled (ENABLE_TCP_443=0)."
  fi

  # Hardening: do NOT open admin externally
  if [[ "${ALLOW_ADMIN_943_EXTERNALLY}" != "0" ]]; then
    echo "ERROR: Hardening policy: Admin UI must not be exposed externally."
    echo "       Use SSH port forwarding instead."
    exit 1
  fi
}

wait_for_container_running() {
  local tries=60
  while (( tries > 0 )); do
    if docker ps --format '{{.Names}}' | grep -qx 'openvpn-as'; then
      return 0
    fi
    sleep 1
    tries=$((tries - 1))
  done
  return 1
}

wait_for_sacli_ready() {
  local tries=180
  while (( tries > 0 )); do
    if docker exec -i openvpn-as /bin/bash -lc 'sacli status >/dev/null 2>&1'; then
      return 0
    fi
    sleep 1
    tries=$((tries - 1))
  done
  return 1
}

set_admin_password_if_requested() {
  if [[ -z "${ADMIN_PASSWORD}" ]]; then
    return 0
  fi

  echo "[init] Waiting for sacli to be ready..."
  if ! wait_for_sacli_ready; then
    echo "ERROR: sacli not ready yet."
    echo "Check logs:"
    echo "  sudo docker logs -n 200 openvpn-as"
    exit 1
  fi

  echo "[init] Setting admin password via sacli (user: openvpn)"
  docker exec -i openvpn-as /bin/bash -lc \
    "sacli --user \"openvpn\" --new_pass \"${ADMIN_PASSWORD}\" SetLocalPassword" >/dev/null

  docker exec -i openvpn-as /bin/bash -lc "sacli start" >/dev/null
  echo "[init] Admin password set."
}

main() {
  need_root
  ensure_prereqs
  ensure_host_fw_exists

  mkdir -p "${DATA_DIR}"

  add_host_fw_rules

  echo "[init] Starting OpenVPN Access Server"
  compose up -d

  if ! wait_for_container_running; then
    echo "ERROR: Container did not start in time. Check logs:"
    echo "  sudo docker logs -n 200 openvpn-as"
    exit 1
  fi

  set_admin_password_if_requested

  echo
  echo "OK."
  echo "Admin UI (via SSH tunnel ONLY):"
  echo "  ssh -fN -o ExitOnForwardFailure=yes -L 1943:127.0.0.1:${AS_ADMIN_PORT} ubuntu@<SERVER_IP>"
  echo "  then open: https://localhost:1943/admin"
  echo
  echo "VPN endpoint:"
  echo "  UDP ${AS_UDP_PORT} is open on host firewall."
  if [[ "${ENABLE_TCP_443}" == "1" ]]; then
    echo "  TCP ${AS_TCP_PORT} is also open (optional)."
  fi
}

main "$@"
