#!/usr/bin/env bash
set -euo pipefail

# ---------------------------
# Config
# ---------------------------
COMPOSE_FILE="${COMPOSE_FILE:-./compose.yaml}"
DATA_DIR="${DATA_DIR:-./openvpn-as-data}"

# Ports (documented defaults for this image)
AS_ADMIN_PORT="${AS_ADMIN_PORT:-943}"
AS_TCP_PORT="${AS_TCP_PORT:-443}"
AS_UDP_PORT="${AS_UDP_PORT:-1194}"

# nftables dedicated table name (we only manage this table)
NFT_TABLE="${NFT_TABLE:-openvpn_as_filter}"

# Optional: restrict Admin UI (943) to a single public IP/CIDR (recommended)
# Example: ADMIN_ALLOW_CIDR="203.0.113.10/32"
ADMIN_ALLOW_CIDR="${ADMIN_ALLOW_CIDR:-}"

# Optional: set admin password automatically after first boot
# Example: ADMIN_PASSWORD="StrongPasswordHere"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Please run as root (sudo)."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

ensure_prereqs() {
  have_cmd docker || { echo "ERROR: docker not found."; exit 1; }
  docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose plugin not available."; exit 1; }
  have_cmd nft || { echo "ERROR: nft not found. Install: sudo apt-get install -y nftables"; exit 1; }
}

warn_admin_allow_cidr() {
  if [[ -z "${ADMIN_ALLOW_CIDR}" ]]; then
    echo "[init] ADMIN_ALLOW_CIDR not set: Admin UI (943) will be reachable from anywhere."
    echo "       Recommended: set ADMIN_ALLOW_CIDR to YOUR public IP (e.g. x.x.x.x/32)."
    return 0
  fi

  # Very lightweight validation (CIDR contains /)
  if [[ "${ADMIN_ALLOW_CIDR}" != */* ]]; then
    echo "ERROR: ADMIN_ALLOW_CIDR must be in CIDR form, e.g. 203.0.113.10/32"
    exit 1
  fi

  echo "[init] Admin UI (943) will be allowed only from: ${ADMIN_ALLOW_CIDR}"
  echo "       Note: This should be your CLIENT public IP, not the server IP."
}

apply_nft_rules() {
  # We only manage our own dedicated table. We do NOT flush the whole ruleset.
  nft "add table inet ${NFT_TABLE}" 2>/dev/null || true
  nft "flush table inet ${NFT_TABLE}"

  # Hook to input only; policy accept so we don't break existing firewall setups.
  nft "add chain inet ${NFT_TABLE} input { type filter hook input priority 0; policy accept; }"

  # Allow VPN ports
  nft "add rule inet ${NFT_TABLE} input udp dport ${AS_UDP_PORT} accept"
  nft "add rule inet ${NFT_TABLE} input tcp dport ${AS_TCP_PORT} accept"

  # Admin UI: allow either from anywhere, or restrict to ADMIN_ALLOW_CIDR
  if [[ -n "${ADMIN_ALLOW_CIDR}" ]]; then
    nft "add rule inet ${NFT_TABLE} input ip saddr ${ADMIN_ALLOW_CIDR} tcp dport ${AS_ADMIN_PORT} accept"
  else
    nft "add rule inet ${NFT_TABLE} input tcp dport ${AS_ADMIN_PORT} accept"
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
  # Wait until sacli can talk to the agent (socket path can vary by image/version)
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

  # Ensure service is started/reloaded after password change
  docker exec -i openvpn-as /bin/bash -lc "sacli start" >/dev/null

  echo "[init] Admin password set."
}

main() {
  need_root
  ensure_prereqs

  mkdir -p "${DATA_DIR}"

  warn_admin_allow_cidr

  echo "[init] Applying nftables rules (table: inet ${NFT_TABLE})"
  apply_nft_rules

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
  echo "After login: set the public hostname/IP in Admin UI:"
  echo "  Configuration -> Network Settings -> Hostname or IP Address"
}

main "$@"
