#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/remote/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd virsh crontab flock timeout

WATCHDOG_DIR="$STATE_DIR/bin"
WATCHDOG_SCRIPT="$WATCHDOG_DIR/ccsvm-vm-watchdog"
CRON_MARKER="# claude-code-sec-vm watchdog"
mkdir -p "$WATCHDOG_DIR" "$STATE_DIR/runtime"

cat >"$WATCHDOG_SCRIPT" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

vm_name=$(printf '%q' "$DEV_VM_NAME")
dev_ip=$(printf '%q' "$DEV_IP")
runtime_dir=$(printf '%q' "$STATE_DIR/runtime")
threshold=3

mkdir -p "\$runtime_dir"
lock_file="\$runtime_dir/watchdog.lock"
failure_file="\$runtime_dir/watchdog.failures"
status_file="\$runtime_dir/watchdog.status"
log_file="\$runtime_dir/watchdog.log"

read_failures() {
  if [[ -f "\$failure_file" ]]; then
    cat "\$failure_file"
  else
    printf '0\\n'
  fi
}

write_failures() {
  printf '%s\\n' "\$1" >"\$failure_file"
}

tcp_ok() {
  timeout 3s bash -c "</dev/tcp/\$dev_ip/22" >/dev/null 2>&1
}

record_status() {
  local state=\$1
  local ssh_state=\$2
  local failures=\$3
  local action=\$4
  {
    printf 'last_check=%s\\n' "\$(date -Is)"
    printf 'vm_state=%s\\n' "\$state"
    printf 'ssh_tcp=%s\\n' "\$ssh_state"
    printf 'failures=%s\\n' "\$failures"
    printf 'action=%s\\n' "\$action"
  } >"\$status_file"
}

log_action() {
  printf '%s %s\\n' "\$(date -Is)" "\$*" >>"\$log_file"
}

(
  flock -n 9 || exit 0

  if ! virsh -c qemu:///system dominfo "\$vm_name" >/dev/null 2>&1; then
    record_status missing unknown 0 none
    exit 0
  fi

  state=\$(virsh -c qemu:///system domstate "\$vm_name" 2>/dev/null || printf 'unknown')
  failures=\$(read_failures)
  action=none
  ssh_state=fail

  if [[ "\$state" != running ]]; then
    virsh -c qemu:///system start "\$vm_name" >/dev/null
    log_action "start vm"
    failures=0
    action=start
    ssh_state=starting
  elif tcp_ok; then
    failures=0
    ssh_state=ok
  else
    failures=\$((failures + 1))
    if ((failures >= threshold)); then
      virsh -c qemu:///system reset "\$vm_name" >/dev/null
      log_action "reset vm after ssh failures"
      failures=0
      action=reset
      ssh_state=resetting
    fi
  fi

  write_failures "\$failures"
  record_status "\$state" "\$ssh_state" "\$failures" "\$action"
) 9>"\$lock_file"
SCRIPT
chmod 0755 "$WATCHDOG_SCRIPT"

watchdog_entry="* * * * * $(printf '%q' "$WATCHDOG_SCRIPT") >/dev/null 2>&1 $CRON_MARKER"
{
  crontab -l 2>/dev/null | grep -Fv "$CRON_MARKER" || true
  printf '%s\n' "$watchdog_entry"
} | crontab -

"$WATCHDOG_SCRIPT" || true

printf 'watchdog=enabled interval=60s threshold=3\n'
