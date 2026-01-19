#!/usr/bin/env bash
set -euo pipefail

# ---------------------------
# Config (edit if you want)
# ---------------------------
VPN_HOST="${VPN_HOST:-vpn.example.com}"   # Public IP or domain for clients
VPN_PORT="${VPN_PORT:-1194}"             # OpenVPN UDP port
VPN_SUBNET="${VPN_SUBNET:-10.8.0.0/24}"  # Must match OpenVPN default unless you change genconfig
VPN_DEV="${VPN_DEV:-tun0}"               # OpenVPN tunnel device name

# DNS servers pushed to clients (optional). Example: "1.1.1.1 8.8.8.8"
PUSH_DNS="${PUSH_DNS:-}"

DATA_DIR="${DATA_DIR:-./openvpn-data}"
COMPOSE_FILE="${COMPOSE_FILE:-./compose.yaml}"

NFT_TABLE_INET="${NFT_TABLE_INET:-openvpn_filter}"
NFT_TABLE_NAT="${NFT_TABLE_NAT:-openvpn_nat}"

# ---------------------------
# Helpers
# ---------------------------
need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Please run as root (sudo)."
    exit 1
  fi
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

detect_wan_if() {
  # Detect outbound interface used for default internet route
  ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

enable_ip_forward() {
  # Enable immediately
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  # Persist
  install -d /etc/sysctl.d
  cat >/etc/sysctl.d/99-openvpn.conf <<EOF
# Managed by openvpn-init.sh
net.ipv4.ip_forward=1
EOF
}

ensure_dirs() {
  mkdir -p "${DATA_DIR}"
}

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

ensure_prereqs() {
  have_cmd docker || { echo "ERROR: docker not found."; exit 1; }
  have_cmd nft || { echo "ERROR: nft (nftables) not found. Install: sudo apt-get install -y nftables"; exit 1; }
  docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose plugin not available."; exit 1; }
}

apply_nft_rules() {
  local wan_if="$1"

  # Create / replace dedicated nft tables without touching the rest of the ruleset
  # Note: This assumes your main firewall policy is not relying on a single global flush.
  # We DO NOT flush the whole ruleset. We only recreate our own tables.

  # inet filter table
  nft "add table inet ${NFT_TABLE_INET}" 2>/dev/null || true

  nft "flush table inet ${NFT_TABLE_INET}"

  nft "add chain inet ${NFT_TABLE_INET} input { type filter hook input priority 0; policy accept; }"
  nft "add chain inet ${NFT_TABLE_INET} forward { type filter hook forward priority 0; policy accept; }"

  # Allow OpenVPN UDP port inbound
  nft "add rule inet ${NFT_TABLE_INET} input udp dport ${VPN_PORT} accept"

  # Forwarding rules for tun -> wan, wan -> tun (stateful)
  nft "add rule inet ${NFT_TABLE_INET} forward ct state established,related accept"
  nft "add rule inet ${NFT_TABLE_INET} forward iifname \"${VPN_DEV}\" oifname \"${wan_if}\" accept"
  nft "add rule inet ${NFT_TABLE_INET} forward iifname \"${wan_if}\" oifname \"${VPN_DEV}\" ct state established,related accept"

  # ip nat table for masquerade
  nft "add table ip ${NFT_TABLE_NAT}" 2>/dev/null || true
  nft "flush table ip ${NFT_TABLE_NAT}"
  nft "add chain ip ${NFT_TABLE_NAT} postrouting { type nat hook postrouting priority 100; policy accept; }"
  nft "add rule ip ${NFT_TABLE_NAT} postrouting oifname \"${wan_if}\" ip saddr ${VPN_SUBNET} masquerade"

  # Ensure nftables service enabled (so tables survive reboot)
  systemctl enable --now nftables >/dev/null 2>&1 || true
}

generate_openvpn_config_if_missing() {
  # If openvpn.conf missing, assume not initialized
  if [[ ! -f "${DATA_DIR}/openvpn.conf" ]]; then
    echo "[init] Generating OpenVPN config for udp://${VPN_HOST}:${VPN_PORT}"

    local args=(ovpn_genconfig -u "udp://${VPN_HOST}:${VPN_PORT}")

    # Optional DNS push
    if [[ -n "${PUSH_DNS}" ]]; then
      # Split PUSH_DNS by spaces
      for dns in ${PUSH_DNS}; do
        args+=(-n "${dns}")
      done
    fi

    # Run config generator
    compose run --rm openvpn "${args[@]}"
  else
    echo "[init] Found existing ${DATA_DIR}/openvpn.conf (skipping ovpn_genconfig)"
  fi
}

init_pki_if_missing() {
  # kylemanna/openvpn stores PKI under /etc/openvpn/pki
  if [[ ! -d "${DATA_DIR}/pki" ]]; then
    echo "[init] Initializing PKI (ovpn_initpki)"
    compose run --rm openvpn ovpn_initpki
  else
    echo "[init] Found existing PKI at ${DATA_DIR}/pki (skipping ovpn_initpki)"
  fi
}

main() {
  need_root
  ensure_prereqs
  ensure_dirs

  local wan_if
  wan_if="$(detect_wan_if || true)"
  if [[ -z "${wan_if}" ]]; then
    echo "ERROR: Could not detect WAN interface. Set it manually via WAN_IF env and modify script if needed."
    exit 1
  fi

  echo "[init] WAN interface detected: ${wan_if}"

  enable_ip_forward
  apply_nft_rules "${wan_if}"

  # Initialize OpenVPN data/config/PKI if needed
  generate_openvpn_config_if_missing
  init_pki_if_missing

  # Start service
  echo "[init] Starting OpenVPN via docker compose"
  compose up -d

  echo
  echo "Done."
  echo "- Data dir: ${DATA_DIR}"
  echo "- UDP port: ${VPN_PORT}"
  echo "- VPN subnet (for NAT): ${VPN_SUBNET}"
  echo
  echo "Next:"
  echo "  sudo ./openvpn-up.sh               # ensure it is running"
  echo "  sudo docker compose -f ${COMPOSE_FILE} logs -f openvpn"
  echo
  echo "Create client profile example:"
  echo "  sudo docker compose -f ${COMPOSE_FILE} run --rm openvpn easyrsa build-client-full client1 nopass"
  echo "  sudo docker compose -f ${COMPOSE_FILE} run --rm openvpn ovpn_getclient client1 > client1.ovpn"
}

main "$@"
