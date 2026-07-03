#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

src=$(remote_src_dir)
ssh_remote "test -f $(shell_quote "$src/scripts/remote/destroy.sh")" || fail "remote source missing; run make up once or sync manually"
run_remote_script scripts/remote/destroy.sh
