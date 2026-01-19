#!/usr/bin/env bash
set -euo pipefail

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

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

remove_nft_rules() {
  # Remove only our dedicated tables
  nft "delete table inet ${NFT_TABLE_INET}" 2>/dev/null || true
  nft "delete table ip ${NFT_TABLE_NAT}" 2>/dev/null || true
}

main() {
  need_root
  have_cmd docker || { echo "ERROR: docker not found."; exit 1; }
  have_cmd nft || { echo "ERROR: nft not found."; exit 1; }
  docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose plugin not available."; exit 1; }

  echo "[down] Stopping OpenVPN"
  compose down

  echo "[down] Removing nftables rules (dedicated tables)"
  remove_nft_rules

  echo "[down] OK"
}

main "$@"
