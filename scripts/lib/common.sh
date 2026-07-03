#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ENV_FILE="$ROOT_DIR/.env.local"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

PROJECT_NAME=${PROJECT_NAME:-claude-code-sec-vm}
REMOTE_HOST=${REMOTE_HOST:-CHANGE_ME_USER@CHANGE_ME_HOST}
REMOTE_WORKDIR=${REMOTE_WORKDIR:-.local/share/claude-code-sec-vm}
SSH_PUBLIC_KEY_PATH=${SSH_PUBLIC_KEY_PATH:-~/.ssh/id_ed25519.pub}
SING_BOX_OUTBOUNDS_FILE=${SING_BOX_OUTBOUNDS_FILE:-$ROOT_DIR/config/secrets/sing-box-outbounds.local.json}
POLICY_FILE=${POLICY_FILE:-$ROOT_DIR/config/egress.policy.yaml}

DEV_VM_NAME=${DEV_VM_NAME:-ccsvm-kali-dev}
LEGACY_GW_VM_NAME=${LEGACY_GW_VM_NAME:-ccsvm-egress-gw}
LAN_NET_NAME=${LAN_NET_NAME:-ccsvm-lan}
LAN_BRIDGE=${LAN_BRIDGE:-ccsvm-lan0}
LAN_HOST_IP=${LAN_HOST_IP:-10.77.0.254}
DEV_IP=${DEV_IP:-10.77.0.10}
LAN_CIDR=${LAN_CIDR:-10.77.0.0/24}

DEV_LAN_MAC=${DEV_LAN_MAC:-52:54:00:77:00:10}

DEV_VM_CPU=${DEV_VM_CPU:-4}
DEV_VM_MEMORY_MB=${DEV_VM_MEMORY_MB:-8192}
DEV_VM_DISK_GB=${DEV_VM_DISK_GB:-80}

DEV_IMAGE_URL=${DEV_IMAGE_URL:-auto}
SING_BOX_INSTALL_SCRIPT_URL=${SING_BOX_INSTALL_SCRIPT_URL:-https://sing-box.app/deb-install.sh}
FOREIGN_CHECK_URL=${FOREIGN_CHECK_URL:-https://www.cloudflare.com/cdn-cgi/trace}

SSH_OPTS=(
  -o ConnectTimeout=8
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=2
  -o ForwardAgent=no
  -o ClearAllForwardings=yes
)

log() {
  printf '[%s] %s\n' "$PROJECT_NAME" "$*" >&2
}

fail() {
  printf '[%s] ERROR: %s\n' "$PROJECT_NAME" "$*" >&2
  exit 1
}

shell_quote() {
  local value=${1-}
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

expanded_public_key_path() {
  local path=$SSH_PUBLIC_KEY_PATH
  if [[ $path == ~/* ]]; then
    path="$HOME/${path#~/}"
  fi
  printf '%s\n' "$path"
}

require_file() {
  local path=$1
  [[ -f "$path" ]] || fail "missing file: $path"
}

ssh_remote() {
  ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "$@"
}

remote_env_exports() {
  local pairs=(
    "PROJECT_NAME=$PROJECT_NAME"
    "REMOTE_WORKDIR=$REMOTE_WORKDIR"
    "DEV_VM_NAME=$DEV_VM_NAME"
    "LEGACY_GW_VM_NAME=$LEGACY_GW_VM_NAME"
    "LAN_NET_NAME=$LAN_NET_NAME"
    "LAN_BRIDGE=$LAN_BRIDGE"
    "LAN_HOST_IP=$LAN_HOST_IP"
    "DEV_IP=$DEV_IP"
    "LAN_CIDR=$LAN_CIDR"
    "DEV_LAN_MAC=$DEV_LAN_MAC"
    "DEV_VM_CPU=$DEV_VM_CPU"
    "DEV_VM_MEMORY_MB=$DEV_VM_MEMORY_MB"
    "DEV_VM_DISK_GB=$DEV_VM_DISK_GB"
    "DEV_IMAGE_URL=$DEV_IMAGE_URL"
    "SING_BOX_INSTALL_SCRIPT_URL=$SING_BOX_INSTALL_SCRIPT_URL"
    "FOREIGN_CHECK_URL=$FOREIGN_CHECK_URL"
    "PURGE=${PURGE:-0}"
  )

  local pair key value
  for pair in "${pairs[@]}"; do
    key=${pair%%=*}
    value=${pair#*=}
    printf '%s=%s ' "$key" "$(shell_quote "$value")"
  done
}

remote_src_dir() {
  printf '%s/src\n' "$REMOTE_WORKDIR"
}

sync_project() {
  local upload_secret=${1:-true}
  local public_key_path
  public_key_path=$(expanded_public_key_path)
  require_file "$public_key_path"

  log "syncing repository to $REMOTE_HOST:$REMOTE_WORKDIR/src"
  ssh_remote "mkdir -p $(shell_quote "$REMOTE_WORKDIR/src") $(shell_quote "$REMOTE_WORKDIR/src/runtime") $(shell_quote "$REMOTE_WORKDIR/src/config/secrets") && chmod 700 $(shell_quote "$REMOTE_WORKDIR/src/config/secrets")"

  COPYFILE_DISABLE=1 tar --no-xattrs -C "$ROOT_DIR" \
    --exclude '.git' \
    --exclude '.env.local' \
    --exclude 'runtime' \
    --exclude 'state' \
    --exclude 'images' \
    --exclude 'volumes' \
    --exclude 'config/secrets/*' \
    -czf - . | ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "rm -rf $(shell_quote "$REMOTE_WORKDIR/src.tmp") && mkdir -p $(shell_quote "$REMOTE_WORKDIR/src.tmp") && tar -xzf - -C $(shell_quote "$REMOTE_WORKDIR/src.tmp") && rm -rf $(shell_quote "$REMOTE_WORKDIR/src") && mv $(shell_quote "$REMOTE_WORKDIR/src.tmp") $(shell_quote "$REMOTE_WORKDIR/src") && mkdir -p $(shell_quote "$REMOTE_WORKDIR/src/runtime") $(shell_quote "$REMOTE_WORKDIR/src/config/secrets") && chmod 700 $(shell_quote "$REMOTE_WORKDIR/src/config/secrets")"

  scp "${SSH_OPTS[@]}" "$public_key_path" "$REMOTE_HOST:$REMOTE_WORKDIR/src/runtime/authorized_keys.pub" >/dev/null

  if [[ $upload_secret == true ]]; then
    require_file "$SING_BOX_OUTBOUNDS_FILE"
    scp "${SSH_OPTS[@]}" "$SING_BOX_OUTBOUNDS_FILE" "$REMOTE_HOST:$REMOTE_WORKDIR/src/config/secrets/sing-box-outbounds.local.json.tmp" >/dev/null
    ssh_remote "mv $(shell_quote "$REMOTE_WORKDIR/src/config/secrets/sing-box-outbounds.local.json.tmp") $(shell_quote "$REMOTE_WORKDIR/src/config/secrets/sing-box-outbounds.local.json") && chmod 600 $(shell_quote "$REMOTE_WORKDIR/src/config/secrets/sing-box-outbounds.local.json")"
  fi
}

run_remote_script() {
  local script=$1
  shift || true
  local src
  src=$(remote_src_dir)
  local envs
  envs=$(remote_env_exports)
  local quoted_args=()
  local arg
  for arg in "$@"; do
    quoted_args+=("$(shell_quote "$arg")")
  done
  ssh_remote "cd $(shell_quote "$src") && $envs bash $(shell_quote "$script") ${quoted_args[*]-}"
}
