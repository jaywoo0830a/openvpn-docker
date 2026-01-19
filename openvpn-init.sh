#!/usr/bin/env bash
set -euo pipefail

# ---------------------------
# Config
# ---------------------------
COMPOSE_FILE="${COMPOSE_FILE:-./compose.yaml}"
DATA_DIR="${DATA_DIR:-./openvpn-as-data}"

AS_ADMIN_PORT="${AS_ADMIN_PORT:-943}"
AS_TCP_PORT="${AS_TCP_PORT:-443}"
AS_UDP_PORT="${AS_UDP_PORT:-1194}"

# Optional: restrict Admin UI (943) to a single public IP/CIDR (recommended)
# Example: ADMIN_ALLOW_CIDR="203.0.113.10/32"
ADMIN_ALLOW_CIDR="${ADMIN_ALLOW_CIDR:-}"

# Optional: set admin password automatically after first boot
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

# We will manage rules in inet host_fw input chain only.
NFT_HOST_TABLE="inet"
NFT_HOST_FW_TABLE="host_fw"
NFT_HOST_CHAIN="input"

# Tag our rules so we can delete them safely later.
RULE_TAG_PREFIX="managed-by=openvpn-as"
RULE_TAG_UDP="${RULE_TAG_PREFIX};port=udp:${AS_UDP_PORT}"
RULE_TAG_TCP443="${RULE_TAG_PREFIX};port=tcp:${AS_TCP_PORT}"
RULE_TAG_ADMIN="${RULE_TAG_PREFIX};port=tcp:${AS_ADMIN_PORT}"

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
  have_cmd systemctl || true
}

warn_admin_allow_cidr() {
  if [[ -z "${ADMIN_ALLOW_CIDR}" ]]; then
    echo "[init] ADMIN_ALLOW_CIDR not set: Admin UI (943) will be reachable from anywhere (if allowed in host_fw)."
    echo "       Recommended: set ADMIN_ALLOW_CIDR to YOUR client public IP (e.g. x.x.x.x/32)."
    return 0
  fi

  if [[ "${ADMIN_ALLOW_CIDR}" != */* ]]; then
    echo "ERROR: ADMIN_ALLOW_CIDR must be in CIDR form, e.g. 203.0.113.10/32"
    exit 1
  fi

  echo "[init] Admin UI (943) will be allowed only from: ${ADMIN_ALLOW_CIDR}"
  echo "       Note: This should be your CLIENT public IP, not the server IP."
}

ensure_host_fw_exists() {
  # Ensure the table/chain exist. If user has different firewall design, fail loudly.
  if ! nft list table inet host_fw >/dev/null 2>&1; then
    echo "ERROR: nft table 'inet host_fw' not found."
    echo "       Your firewall uses a different structure; adjust scripts accordingly."
    exit 1
  fi

  if ! nft list chain inet host_fw input >/dev/null 2>&1; then
    echo "ERROR: nft chain 'inet host_fw input' not found."
    exit 1
  fi
}

rule_exists_by_comment() {
  # Check if a rule with given comment exists in host_fw input
  local comment="$1"
  nft -a list chain inet host_fw input | grep -F "comment \"${comment}\"" >/dev/null 2>&1
}

add_host_fw_rules() {
  ensure_host_fw_exists

  echo "[init] Adding rules to inet host_fw input (these are the rules that actually matter with policy drop)."

  # UDP 1194
  if ! rule_exists_by_comment "${RULE_TAG_UDP}"; then
    nft add rule inet host_fw input udp dport "${AS_UDP_PORT}" ct state new accept comment "${RULE_TAG_UDP}"
  fi

  # TCP 443 (optional but recommended for environments blocking UDP)
  if ! rule_exists_by_comment "${RULE_TAG_TCP443}"; then
    nft add rule inet host_fw input tcp dport "${AS_TCP_PORT}" ct state new accept comment "${RULE_TAG_TCP443}"
  fi

  # Admin UI 943 (either restricted or open)
  if [[ -n "${ADMIN_ALLOW_CIDR}" ]]; then
    if ! rule_exists_by_comment "${RULE_TAG_ADMIN};src=${ADMIN_ALLOW_CIDR}"; then
      nft add rule inet host_fw input ip saddr "${ADMIN_ALLOW_CIDR}" tcp dport "${AS_ADMIN_PORT}" ct state new accept \
        comment "${RULE_TAG_ADMIN};src=${ADMIN_ALLOW_CIDR}"
    fi
  else
    if ! rule_exists_by_comment "${RULE_TAG_ADMIN}"; then
      nft add rule inet host_fw input tcp dport "${AS_ADMIN_PORT}" ct state new accept comment "${RULE_TAG_ADMIN}"
    fi
  fi

  systemctl enable --now nftables >/dev/null 2>&1 || true
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

  mkdir -p "${DATA_DIR}"

  warn_admin_allow_cidr

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
  echo "Admin UI:   https://<SERVER_IP>:${AS_ADMIN_PORT}/admin"
  echo "Client UI:  https://<SERVER_IP>:${AS_ADMIN_PORT}/"
  echo
  echo "Default admin user: openvpn"
  echo "If you didn't set ADMIN_PASSWORD, initial password is shown in logs on first run:"
  echo "  sudo docker logs -f openvpn-as"
  echo
  echo "Recommended: keep Admin UI closed externally and use SSH port forwarding:"
  echo "  ssh -fN -o ExitOnForwardFailure=yes -L 1943:127.0.0.1:${AS_ADMIN_PORT} ubuntu@<SERVER_IP>"
}

main "$@"
