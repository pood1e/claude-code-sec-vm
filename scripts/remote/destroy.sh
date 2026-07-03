#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/remote/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd virsh sudo nft

remove_domain() {
  local name=$1
  if ! domain_exists "$name"; then
    log "domain missing: $name"
    return
  fi
  if [[ $(virsh -c qemu:///system domstate "$name" 2>/dev/null || true) == running ]]; then
    virsh -c qemu:///system destroy "$name" >/dev/null || true
  fi
  virsh -c qemu:///system undefine "$name" --nvram >/dev/null 2>&1 || virsh -c qemu:///system undefine "$name" >/dev/null
}

remove_network() {
  if ! network_exists "$LAN_NET_NAME"; then
    return
  fi
  if network_active "$LAN_NET_NAME"; then
    virsh -c qemu:///system net-destroy "$LAN_NET_NAME" >/dev/null || true
  fi
  virsh -c qemu:///system net-undefine "$LAN_NET_NAME" >/dev/null || true
}

remove_host_network_state() {
  if sudo -n true >/dev/null 2>&1; then
    sudo_run systemctl disable --now ccsvm-transparent-gateway.service >/dev/null 2>&1 || true
    sudo_run systemctl disable --now ccsvm-sing-box.service >/dev/null 2>&1 || true
    sudo_run nft delete table inet ccsvm_transparent >/dev/null 2>&1 || true
    sudo_run nft delete table inet ccsvm_host_guard >/dev/null 2>&1 || true
    sudo_run ip rule del priority 10077 fwmark 0x77 table 10077 >/dev/null 2>&1 || true
    sudo_run ip route flush table 10077 >/dev/null 2>&1 || true
    sudo_run rm -f /etc/nftables.d/ccsvm-host-guard.nft
  else
    log "sudo is not passwordless; skipping host transparent gateway cleanup"
  fi
}

remove_domain "$DEV_VM_NAME"
remove_domain "$LEGACY_GW_VM_NAME"
remove_network
remove_host_network_state
rm -rf "$VOLUME_DIR" "$SEED_DIR" "$RUNTIME_DIR"
if [[ ${PURGE:-0} == 1 ]]; then
  rm -rf "$IMAGE_DIR"
fi
log "destroyed generated VM state; PURGE=${PURGE:-0}"
