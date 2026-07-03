#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

bash "$ROOT_DIR/scripts/host-transparent-enable.sh"
bash "$ROOT_DIR/scripts/kali-transparent-enable.sh"
