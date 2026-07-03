#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RELAY_DIR="$REMOTE_WORKDIR/runtime/vnc-relay"
PID_FILE="$RELAY_DIR/relay.pid"
remote_script=$(cat <<'REMOTE'
set -euo pipefail
if sudo -n true >/dev/null 2>&1; then
  sudo -n systemctl disable --now ccsvm-vnc-forward.service >/dev/null 2>&1 || true
  sudo -n nft list table ip ccsvm_vnc >/dev/null 2>&1 && sudo -n nft delete table ip ccsvm_vnc || true
  sudo -n rm -f /etc/systemd/system/ccsvm-vnc-forward.service /usr/local/lib/claude-code-sec-vm/vnc-forward.nft /usr/local/lib/claude-code-sec-vm/vnc-forward-apply.sh
  sudo -n systemctl daemon-reload
else
  echo "remote sudo is required to remove nft forwarding rules" >&2
fi
if [ -f "${PID_FILE}" ]; then
  kill "$(cat "${PID_FILE}")" >/dev/null 2>&1 || true
  rm -f "${PID_FILE}"
fi
pkill -f "${REMOTE_WORKDIR}/runtime/vnc-relay.*/tcp_relay.py" >/dev/null 2>&1 || true
printf 'vnc_exposed=disabled\n'
REMOTE
)
ssh_remote "REMOTE_WORKDIR=$(shell_quote "$REMOTE_WORKDIR") RELAY_DIR=$(shell_quote "$RELAY_DIR") PID_FILE=$(shell_quote "$PID_FILE") bash -s" <<<"$remote_script"
