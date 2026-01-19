#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-./compose.yaml}"

AS_ADMIN_PORT="${AS_ADMIN_PORT:-943}"
AS_TCP_PORT="${AS_TCP_PORT:-443}"
AS_UDP_PORT="${AS_UDP_PORT:-1194}"

ADMIN_ALLOW_CIDR="${ADMIN_ALLOW_CIDR:-}"

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

ensure_host_fw_exists() {
  nft list table inet host_fw >/dev/null 2>&1 || { echo "ERROR: nft table 'inet host_fw' not found."; exit 1; }
  nft list chain inet host_fw input >/dev/null 2>&1 || { echo "ERROR: nft chain 'inet host_fw input' not found."; exit 1; }
}

rule_exists_by_comment() {
  local comment="$1"
  nft -a list chain inet host_fw input | grep -F "comment \"${comment}\"" >/dev/null 2>&1
}

apply_host_fw_rules() {
  ensure_host_fw_exists

  if ! rule_exists_by_comment "${RULE_TAG_UDP}"; then
    nft add rule inet host_fw input udp dport "${AS_UDP_PORT}" ct state new accept comment "${RULE_TAG_UDP}"
  fi

  if ! rule_exists_by_comment "${RULE_TAG_TCP443}"; then
    nft add rule inet host_fw input tcp dport "${AS_TCP_PORT}" ct state new accept comment "${RULE_TAG_TCP443}"
  fi

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
}

main() {
  need_root
  have_cmd docker || { echo "ERROR: docker not found."; exit 1; }
  docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose plugin not available."; exit 1; }
  have_cmd nft || { echo "ERROR: nft not found. Install: sudo apt-get install -y nftables"; exit 1; }

  echo "[up] Applying host_fw rules"
  apply_host_fw_rules

  echo "[up] Starting container"
  compose up -d

  echo "[up] OK"
}

main "$@"
