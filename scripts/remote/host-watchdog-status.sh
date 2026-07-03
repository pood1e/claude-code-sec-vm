#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/remote/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CRON_MARKER="# claude-code-sec-vm watchdog"
STATUS_FILE="$STATE_DIR/runtime/watchdog.status"
LOG_FILE="$STATE_DIR/runtime/watchdog.log"

if crontab -l 2>/dev/null | grep -Fq "$CRON_MARKER"; then
  echo "watchdog=enabled"
else
  echo "watchdog=disabled"
fi

printf 'vm_state='
virsh -c qemu:///system domstate "$DEV_VM_NAME" 2>/dev/null || echo unknown

printf 'ssh_tcp='
if timeout 3s bash -c "</dev/tcp/$DEV_IP/22" >/dev/null 2>&1; then
  echo ok
else
  echo fail
fi

printf 'vnc_tcp='
if timeout 3s bash -c "</dev/tcp/$DEV_IP/5901" >/dev/null 2>&1; then
  echo ok
else
  echo fail
fi

if [[ -f "$STATUS_FILE" ]]; then
  while IFS='=' read -r key value; do
    [[ -n "$key" ]] || continue
    printf 'watchdog_%s=%s\n' "$key" "$value"
  done <"$STATUS_FILE"
else
  echo "watchdog_last_check=none"
fi

printf 'last_action='
if [[ -f "$LOG_FILE" ]]; then
  tail -n 1 "$LOG_FILE"
else
  echo none
fi
