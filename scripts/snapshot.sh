#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

snapshot=${1:-clean}
src=$(remote_src_dir)
ssh_remote "test -f $(shell_quote "$src/scripts/remote/snapshot.sh")" || fail "remote source missing; run make up first"
run_remote_script scripts/remote/snapshot.sh "$snapshot"
