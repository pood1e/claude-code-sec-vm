#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SSH_USER=${SSH_USER:-dev}
exec ssh \
  "${SSH_VM_OPTS[@]}" \
  "$SSH_USER@$DEV_IP" "$@"
