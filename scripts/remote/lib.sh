#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME=${PROJECT_NAME:-claude-code-sec-vm}
REMOTE_WORKDIR=${REMOTE_WORKDIR:-.local/share/claude-code-sec-vm}
DEV_VM_NAME=${DEV_VM_NAME:-ccsvm-kali-dev}
LEGACY_GW_VM_NAME=${LEGACY_GW_VM_NAME:-ccsvm-egress-gw}
LAN_NET_NAME=${LAN_NET_NAME:-ccsvm-lan}
LAN_BRIDGE=${LAN_BRIDGE:-ccsvm-lan0}
LAN_HOST_IP=${LAN_HOST_IP:-10.77.0.254}
DEV_IP=${DEV_IP:-10.77.0.10}
LAN_CIDR=${LAN_CIDR:-10.77.0.0/24}
ALLOW_KALI_192_168_0_24=${ALLOW_KALI_192_168_0_24:-0}
DEV_LAN_MAC=${DEV_LAN_MAC:-52:54:00:77:00:10}
DEV_VM_CPU=${DEV_VM_CPU:-4}
DEV_VM_MEMORY_MB=${DEV_VM_MEMORY_MB:-8192}
DEV_VM_DISK_GB=${DEV_VM_DISK_GB:-80}
DEV_IMAGE_URL=${DEV_IMAGE_URL:-auto}
SING_BOX_INSTALL_SCRIPT_URL=${SING_BOX_INSTALL_SCRIPT_URL:-https://sing-box.app/deb-install.sh}

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STATE_DIR="$HOME/$REMOTE_WORKDIR"
IMAGE_DIR="$STATE_DIR/images"
VOLUME_DIR="$STATE_DIR/volumes"
SEED_DIR="$STATE_DIR/seed"
RUNTIME_DIR="$SRC_DIR/runtime"
POLICY_FILE="$SRC_DIR/config/egress.policy.yaml"
OUTBOUNDS_FILE="$SRC_DIR/config/secrets/sing-box-outbounds.local.json"
AUTHORIZED_KEY_FILE="$SRC_DIR/runtime/authorized_keys.pub"

log() {
  printf '[%s:remote] %s\n' "$PROJECT_NAME" "$*" >&2
}

fail() {
  printf '[%s:remote] ERROR: %s\n' "$PROJECT_NAME" "$*" >&2
  exit 1
}

require_cmd() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]})); then
    fail "missing commands: ${missing[*]}"
  fi
}

domain_exists() {
  virsh -c qemu:///system dominfo "$1" >/dev/null 2>&1
}

network_exists() {
  virsh -c qemu:///system net-info "$1" >/dev/null 2>&1
}

network_active() {
  [[ $(virsh -c qemu:///system net-info "$1" 2>/dev/null | awk '/Active:/ {print $2}') == yes ]]
}

sudo_run() {
  sudo "$@"
}

wait_for_tcp() {
  local host=$1
  local port=$2
  local tries=${3:-90}
  local index
  for ((index = 1; index <= tries; index++)); do
    if timeout 3s bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}
