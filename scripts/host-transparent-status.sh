#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

remote_command=$(cat <<'REMOTE'
set -euo pipefail
printf 'ccsvm_sing_box=%s\n' "$(systemctl is-active ccsvm-sing-box.service 2>/dev/null || true)"
printf 'transparent_gateway=%s\n' "$(systemctl is-active ccsvm-transparent-gateway.service 2>/dev/null || true)"
printf 'scope_iif=%s\n' "$LAN_BRIDGE"
printf 'scope_src=%s\n' "$DEV_IP"
if ip rule show | grep -q '10077:.*fwmark 0x77.*lookup 10077'; then
  printf 'policy_route=ok\n'
else
  printf 'policy_route=missing\n'
fi
if sudo -n nft list table inet ccsvm_transparent >/dev/null 2>&1; then
  printf 'nft_table=ok\n'
elif nft list table inet ccsvm_transparent >/dev/null 2>&1; then
  printf 'nft_table=ok\n'
else
  printf 'nft_table=unknown-sudo-required-or-missing\n'
fi
if ip route show default 0.0.0.0/0 | grep -q .; then
  printf 'host_default_route=present\n'
else
  printf 'host_default_route=missing\n'
fi
printf 'host_output=untouched\n'
REMOTE
)

ssh_remote \
  "LAN_BRIDGE=$(shell_quote "$LAN_BRIDGE") DEV_IP=$(shell_quote "$DEV_IP") bash -s" <<<"$remote_command"
