#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

public_key_path=$(expanded_public_key_path)
require_file "$POLICY_FILE"
require_file "$public_key_path"

log "checking local policy"
python3 "$ROOT_DIR/scripts/policy_value.py" --policy "$POLICY_FILE" timezone.foreign_clean >/dev/null
python3 "$ROOT_DIR/scripts/policy_value.py" --policy "$POLICY_FILE" default_outbound >/dev/null

if [[ -f "$SING_BOX_OUTBOUNDS_FILE" ]]; then
  tmp=$(mktemp)
  python3 "$ROOT_DIR/scripts/render_sing_box_config.py" \
    --policy "$POLICY_FILE" \
    --outbounds "$SING_BOX_OUTBOUNDS_FILE" \
    --output "$tmp"
  rm -f "$tmp"
else
  log "proxy outbounds file is missing; create config/secrets/sing-box-outbounds.local.json before make transparent-enable"
fi

log "checking remote host: $REMOTE_HOST"
ssh_remote '
set -euo pipefail
printf "host="; hostname
printf "date="; date -Is
printf "user="; id -un
printf "groups="; id -nG
for cmd in virsh virt-install qemu-img cloud-localds python3 curl tar xz nft sudo; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "missing=$cmd"
    exit 20
  fi
done
if [ ! -r /dev/kvm ] && [ ! -w /dev/kvm ]; then
  echo "kvm=not-accessible"
  exit 21
fi
virsh -c qemu:///system list --all >/dev/null
printf "kvm=ok\nlibvirt=ok\n"
'
log "doctor passed"
