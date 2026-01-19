#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-./compose.yaml}"

AS_TCP_PORT="${AS_TCP_PORT:-443}"
AS_UDP_PORT="${AS_UDP_PORT:-1194}"

RULE_TAG_PREFIX="managed-by=openvpn-as"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Please run as root (sudo)."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }
compose() { docker compose -f "${COMPOSE_FILE}" "$@"; }

ensure_host_fw_exists() {
  nft list table inet host_fw >/dev/null 2>&1 || { echo "ERROR: nft table 'inet host_fw' not found."; exit 1; }
  nft list chain inet host_fw input >/dev/null 2>&1 || { echo "ERROR: nft chain 'inet host_fw input' not found."; exit 1; }
}

delete_rules_by_tag_prefix() {
  local tag_prefix="$1"

  ensure_host_fw_exists

  # Find handles of rules whose comment starts with our prefix
  local handles
  handles="$(nft -a list chain inet host_fw input \
    | grep -F "comment \"${tag_prefix}" \
    | awk '{for (i=1;i<=NF;i++) if ($i=="handle") print $(i+1)}')"

  if [[ -z "${handles}" ]]; then
    return 0
  fi

  while read -r h; do
    [[ -z "${h}" ]] && continue
    nft delete rule inet host_fw input handle "${h}" || true
  done <<< "${handles}"
}

main() {
  need_root
  have_cmd docker || { echo "ERROR: docker not found."; exit 1; }
  docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose plugin not available."; exit 1; }
  have_cmd nft || { echo "ERROR: nft not found. Install: sudo apt-get install -y nftables"; exit 1; }

  echo "[down] Stopping container"
  compose down

  echo "[down] Removing host_fw rules created by this setup (tag: ${RULE_TAG_PREFIX})"
  delete_rules_by_tag_prefix "${RULE_TAG_PREFIX}"

  echo "[down] OK"
}

main "$@"
