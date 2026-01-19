#!/usr/bin/env bash
set -euo pipefail

# ---------------------------
# Config (keep consistent with init)
# ---------------------------
VPN_PORT="${VPN_PORT:-1194}"
VPN_SUBNET="${VPN_SUBNET:-10.8.0.0/24}"
VPN_DEV="${VPN_DEV:-tun0}"

COMPOSE_FILE="${COMPOSE_FILE:-./compose.yaml}"

NFT_TABLE_INET="${NFT_TABLE_INET:-openvpn_filter}"
NFT_TABLE_NAT="${NFT_TABLE_NAT:-openvpn_nat}"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Please run as root (sudo)."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_wan_if() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

apply_nft_rules() {
  local wan_if="$1"

  nft "add table inet ${NFT_TABLE_INET}" 2>/dev/null || true
  nft "flush table inet ${NFT_TABLE_INET}"

  nft "add chain inet ${NFT_TABLE_INET} input { type filter hook input priority 0; policy accept; }"
  nft "add chain inet ${NFT_TABLE_INET} forward { type filter hook forward priority 0; policy accept; }"

  nft "add rule inet ${NFT_TABLE_INET} input udp dport ${VPN_PORT} accept"

  nft "add rule inet ${NFT_TABLE_INET} forward ct state established,related accept"
  nft "add rule inet ${NFT_TABLE_INET} forward iifname \"${VPN_DEV}\" oifname \"${wan_if}\" accept"
  nft "add rule inet ${NFT_TABLE_INET} forward iifname \"${wan_if}\" oifname \"${VPN_DEV}\" ct state established,related accept"

  nft "add table ip ${NFT_TABLE_NAT}" 2>/dev/null || true
  nft "flush table ip ${NFT_TABLE_NAT}"
  nft "add chain ip ${NFT_TABLE_NAT} postrouting { type nat hook postrouting priority 100; policy accept; }"
  nft "add rule ip ${NFT_TABLE_NAT} postrouting oifname \"${wan_if}\" ip saddr ${VPN_SUBNET} masquerade"

  systemctl enable --now nftables >/dev/null 2>&1 || true
}

enable_ip_forward() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

main() {
  need_root
  have_cmd docker || { echo "ERROR: docker not found."; exit 1; }
  have_cmd nft || { echo "ERROR: nft not found."; exit 1; }
  docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose plugin not available."; exit 1; }

  local wan_if
  wan_if="$(detect_wan_if || true)"
  if [[ -z "${wan_if}" ]]; then
    echo "ERROR: Could not detect WAN interface."
    exit 1
  fi

  enable_ip_forward
  apply_nft_rules "${wan_if}"

  echo "[up] Starting OpenVPN"
  compose up -d

  echo "[up] OK"
}

main "$@"
