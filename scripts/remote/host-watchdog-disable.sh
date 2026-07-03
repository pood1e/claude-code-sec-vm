#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/remote/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CRON_MARKER="# claude-code-sec-vm watchdog"
crontab -l 2>/dev/null | grep -Fv "$CRON_MARKER" | crontab - 2>/dev/null || true
rm -f "$STATE_DIR/bin/ccsvm-vm-watchdog"
echo "watchdog=disabled"
