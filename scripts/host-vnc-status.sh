#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

HOST_VNC_PORT=${HOST_VNC_PORT:-5900}
GUEST_VNC_PORT=${GUEST_VNC_PORT:-5901}
RELAY_DIR="$REMOTE_WORKDIR/runtime/vnc-relay"
PID_FILE="$RELAY_DIR/relay.pid"
remote_script=$(cat <<'REMOTE'
set -euo pipefail
printf 'forward_service='; systemctl is-active ccsvm-vnc-forward.service 2>/dev/null || true
printf 'forward='
if sudo -n nft list table ip ccsvm_vnc >/dev/null 2>&1; then
  echo ok
elif sudo -n true >/dev/null 2>&1; then
  echo fail
else
  echo unknown-sudo-required
fi
printf 'relay='
if pgrep -f "${REMOTE_WORKDIR}/runtime/vnc-relay.*/tcp_relay.py" >/dev/null 2>&1; then
  echo ok
elif [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" >/dev/null 2>&1; then
  echo ok
else
  echo fail
fi
printf 'public_socket='
public_socket=$(ss -ltn "sport = :${HOST_VNC_PORT}" 2>/dev/null | awk 'NR>1 && $4 !~ /^127[.]/ && $4 !~ /^\[::1\]/ {print $4}' | paste -sd, -)
if [ -n "${public_socket}" ]; then
  echo "${public_socket}"
else
  echo none-kernel-nat
fi
printf 'host_console_socket='; ss -ltn "sport = :${HOST_VNC_PORT}" 2>/dev/null | awk 'NR>1 && ($4 ~ /^127[.]/ || $4 ~ /^\[::1\]/) {print $4}' | paste -sd, - || true
printf 'target='; if bash -c "</dev/tcp/${DEV_IP}/${GUEST_VNC_PORT}" >/dev/null 2>&1; then echo ok; else echo fail; fi
REMOTE
)
ssh_remote "HOST_VNC_PORT=$(shell_quote "$HOST_VNC_PORT") DEV_IP=$(shell_quote "$DEV_IP") GUEST_VNC_PORT=$(shell_quote "$GUEST_VNC_PORT") REMOTE_WORKDIR=$(shell_quote "$REMOTE_WORKDIR") PID_FILE=$(shell_quote "$PID_FILE") bash -s" <<<"$remote_script"
