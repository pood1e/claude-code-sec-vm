#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/remote/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

snapshot=${1:-clean}
require_cmd virsh

create_snapshot() {
  local domain=$1
  domain_exists "$domain" || fail "domain missing: $domain"
  virsh -c qemu:///system snapshot-create-as \
    --domain "$domain" \
    --name "$snapshot" \
    --description "${PROJECT_NAME} ${snapshot}" \
    --atomic >/dev/null
  log "snapshot created: $domain@$snapshot"
}

create_snapshot "$DEV_VM_NAME"
