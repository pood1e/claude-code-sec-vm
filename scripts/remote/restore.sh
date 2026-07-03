#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/remote/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

snapshot=${1:?snapshot name is required}
require_cmd virsh

restore_snapshot() {
  local domain=$1
  domain_exists "$domain" || fail "domain missing: $domain"
  virsh -c qemu:///system snapshot-info "$domain" "$snapshot" >/dev/null || fail "snapshot missing: $domain@$snapshot"
  virsh -c qemu:///system snapshot-revert "$domain" "$snapshot" --running >/dev/null
  log "snapshot restored: $domain@$snapshot"
}

restore_snapshot "$DEV_VM_NAME"
