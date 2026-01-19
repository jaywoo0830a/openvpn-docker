#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-./compose.yaml}"

AS_ADMIN_PORT="${AS_ADMIN_PORT:-943}"
AS_TCP_PORT="${AS_TCP_PORT:-443}"
AS_UDP_PORT="${AS_UDP_PORT:-1194}"

NFT_TABLE="${NFT_TABLE:-openvpn_as_filter}"
ADMIN_ALLOW_CIDR="${ADMIN_ALLOW_CIDR:-}"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Please run as root (sudo)."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

compose() { docker compose -f "${COMPOSE_FILE}" "$@"; }

apply_nft_rules() {
  nft "add table inet ${NFT_TABLE}" 2>/dev/null || true
  nft "flush table inet ${NFT_TABLE}"
  nft "add chain inet ${NFT_TABLE} input { type filter hook input priority 0; policy accept; }"

  nft "add rule inet ${NFT_TABLE} input udp dport ${AS_UDP_PORT} accept"
  nft "add rule inet ${NFT_TABLE} input tcp dport ${AS_TCP_PORT} accept"

  if [[ -n "${ADMIN_ALLOW_CIDR}" ]]; then
    nft "add rule inet ${NFT_TABLE} input ip saddr ${ADMIN_ALLOW_CIDR} tcp dport ${AS_ADMIN_PORT} accept"
  else
    nft "add rule inet ${NFT_TABLE} input tcp dport ${AS_ADMIN_PORT} accept"
  fi

  systemctl enable --now nftables >/dev/null 2>&1 || true
}

main() {
  need_root
  have_cmd docker || { echo "ERROR: docker not found."; exit 1; }
  docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose plugin not available."; exit 1; }
  have_cmd nft || { echo "ERROR: nft not found."; exit 1; }

  echo "[up] Applying nftables rules"
  apply_nft_rules

  echo "[up] Starting container"
  compose up -d

  echo "[up] OK"
}

main "$@"
