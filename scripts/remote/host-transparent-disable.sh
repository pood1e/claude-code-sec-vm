#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/remote/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TPROXY_MARK=${TPROXY_MARK:-0x77}
TPROXY_TABLE=${TPROXY_TABLE:-10077}

sudo_run() {
  if [[ ${ALLOW_INTERACTIVE_SUDO:-0} == 1 ]]; then
    sudo "$@"
  else
    sudo -n "$@"
  fi
}

if ! sudo_run true >/dev/null 2>&1; then
  fail "remote sudo is required; run from an interactive terminal"
fi

sudo_run systemctl disable --now ccsvm-transparent-gateway.service >/dev/null 2>&1 || true
sudo_run systemctl disable --now ccsvm-sing-box.service >/dev/null 2>&1 || true
sudo_run nft delete table inet ccsvm_transparent >/dev/null 2>&1 || true
sudo_run ip rule del priority "$TPROXY_TABLE" fwmark "$TPROXY_MARK" table "$TPROXY_TABLE" >/dev/null 2>&1 || true
sudo_run ip route flush table "$TPROXY_TABLE" >/dev/null 2>&1 || true
printf 'transparent_gateway=disabled host_output=untouched\n'
