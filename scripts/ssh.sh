#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SSH_USER=${SSH_USER:-dev}
exec ssh \
  -J "$REMOTE_HOST" \
  -o ConnectTimeout=8 \
  -o ServerAliveInterval=5 \
  -o ServerAliveCountMax=2 \
  -o ForwardAgent=no \
  -o ClearAllForwardings=yes \
  -o UserKnownHostsFile=/tmp/ccsvm-known-hosts \
  -o StrictHostKeyChecking=accept-new \
  "$SSH_USER@$DEV_IP" "$@"
