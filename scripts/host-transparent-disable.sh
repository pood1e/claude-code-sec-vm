#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

sync_project false

interactive_sudo=0
if [[ ${HOST_TRANSPARENT_INTERACTIVE_SUDO:-auto} == 1 || ( ${HOST_TRANSPARENT_INTERACTIVE_SUDO:-auto} == auto && -t 0 && -t 1 ) ]]; then
  interactive_sudo=1
fi

ssh_cmd=(ssh "${SSH_OPTS[@]}")
if [[ $interactive_sudo == 1 ]]; then
  ssh_cmd=(ssh -tt "${SSH_OPTS[@]}")
fi

src=$(remote_src_dir)
envs=$(remote_env_exports)
"${ssh_cmd[@]}" "$REMOTE_HOST" \
  "cd $(shell_quote "$src") && ALLOW_INTERACTIVE_SUDO=$(shell_quote "$interactive_sudo") $envs bash scripts/remote/host-transparent-disable.sh"
