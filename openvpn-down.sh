#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-./compose.yaml}"
NFT_TABLE="${NFT_TABLE:-openvpn_as_filter}"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Please run as root (sudo)."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

compose() { docker compose -f "${COMPOSE_FILE}" "$@"; }

main() {
  need_root
  have_cmd docker || { echo "ERROR: docker not found."; exit 1; }
  docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose plugin not available."; exit 1; }
  have_cmd nft || { echo "ERROR: nft not found. Install: sudo apt-get install -y nftables"; exit 1; }

  echo "[down] Stopping container"
  compose down

  echo "[down] Removing nftables table: inet ${NFT_TABLE}"
  nft "delete table inet ${NFT_TABLE}" 2>/dev/null || true

  echo "[down] OK"
}

main "$@"
