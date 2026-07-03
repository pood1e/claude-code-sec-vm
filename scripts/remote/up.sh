#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/remote/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd virsh virt-install qemu-img cloud-localds python3 curl tar find awk
[[ -f "$AUTHORIZED_KEY_FILE" ]] || fail "missing runtime/authorized_keys.pub on remote sync"
mkdir -p "$IMAGE_DIR" "$VOLUME_DIR" "$SEED_DIR"

allow_hypervisor_storage_access() {
  local dir
  for dir in "$HOME" "$HOME/.local" "$HOME/.local/share" "$STATE_DIR" "$IMAGE_DIR" "$VOLUME_DIR" "$SEED_DIR"; do
    [[ -d "$dir" ]] && chmod o+x "$dir" || true
  done
  find "$IMAGE_DIR" "$VOLUME_DIR" "$SEED_DIR" -type f -exec chmod o+r {} + 2>/dev/null || true
}

policy_value() {
  python3 "$SRC_DIR/scripts/policy_value.py" --policy "$POLICY_FILE" "$1"
}

resolve_dev_image_url() {
  if [[ "$DEV_IMAGE_URL" != auto ]]; then
    printf '%s\n' "$DEV_IMAGE_URL"
    return
  fi
  python3 - <<'PY'
from html.parser import HTMLParser
from urllib.request import urlopen

BASE = "https://kali.download/cloud-images/current/"

class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs = []
    def handle_starttag(self, tag, attrs):
        if tag != "a":
            return
        for key, value in attrs:
            if key == "href":
                self.hrefs.append(value)

parser = Links()
with urlopen(BASE, timeout=20) as response:
    parser.feed(response.read().decode("utf-8", "replace"))
images = sorted(href for href in parser.hrefs if href.endswith("cloud-genericcloud-amd64.tar.xz"))
if not images:
    raise SystemExit("no Kali genericcloud amd64 image found")
print(BASE + images[-1])
PY
}

download_image() {
  local url=$1
  local output=$2
  local name=$3
  if [[ -f "$output" ]]; then
    log "$name image exists: $output"
    return
  fi

  local tmp_dir="$IMAGE_DIR/download-$name"
  local download="$tmp_dir/${url##*/}"
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"

  log "downloading $name base image"
  curl -fL --retry 3 --connect-timeout 10 --max-time 3600 -o "$download" "$url"

  local source_image
  case "$download" in
    *.tar.xz)
      tar -xJf "$download" -C "$tmp_dir"
      source_image=$(find "$tmp_dir" -type f \( -name '*.qcow2' -o -name '*.img' -o -name '*.raw' \) | sort | head -n 1)
      [[ -n "$source_image" ]] || fail "no qcow2/img/raw found in $download"
      ;;
    *)
      source_image="$download"
      ;;
  esac

  local converted="$output.tmp"
  qemu-img convert -O qcow2 "$source_image" "$converted"
  mv "$converted" "$output"
  rm -rf "$tmp_dir"
}

image_format() {
  qemu-img info --output=json "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["format"])'
}

create_overlay() {
  local base=$1
  local volume=$2
  local size_gb=$3
  if [[ -f "$volume" ]]; then
    log "volume exists: $volume"
    return
  fi
  local format
  format=$(image_format "$base")
  qemu-img create -f qcow2 -F "$format" -b "$base" "$volume" "${size_gb}G"
}

ensure_lan_network() {
  local net_xml="$RUNTIME_DIR/lan-network.xml"
  cat >"$net_xml" <<XML
<network>
  <name>${LAN_NET_NAME}</name>
  <bridge name='${LAN_BRIDGE}' stp='on' delay='0'/>
  <ip address='${LAN_HOST_IP}' netmask='255.255.255.0'>
    <dhcp>
      <range start='10.77.0.100' end='10.77.0.200'/>
      <host mac='${DEV_LAN_MAC}' name='kali-dev' ip='${DEV_IP}'/>
      <option name='router' value='${LAN_HOST_IP}'/>
    </dhcp>
  </ip>
</network>
XML
  if ! network_exists "$LAN_NET_NAME"; then
    virsh -c qemu:///system net-define "$net_xml"
  fi
  if ! network_active "$LAN_NET_NAME"; then
    virsh -c qemu:///system net-start "$LAN_NET_NAME"
  fi
  virsh -c qemu:///system net-autostart "$LAN_NET_NAME" >/dev/null
}

render_seed() {
  local role=$1
  local user_data="$SEED_DIR/$role-user-data.yaml"
  local network_config="$SEED_DIR/$role-network-config.yaml"
  local meta_data="$SEED_DIR/$role-meta-data.yaml"
  local iso="$SEED_DIR/$role-seed.iso"
  local timezone
  timezone=$(policy_value timezone.foreign_clean)

  python3 "$SRC_DIR/scripts/render_cloud_init.py" \
    --role "$role" \
    --authorized-key-file "$AUTHORIZED_KEY_FILE" \
    --user-data "$user_data" \
    --network-config "$network_config" \
    --lan-host-ip "$LAN_HOST_IP" \
    --dev-ip "$DEV_IP" \
    --dev-lan-mac "$DEV_LAN_MAC" \
    --timezone "$timezone"

  cat >"$meta_data" <<META
instance-id: ${PROJECT_NAME}-${role}
local-hostname: ${role}
META
  rm -f "$iso"
  cloud-localds --network-config="$network_config" "$iso" "$user_data" "$meta_data"
}

ensure_domain_started() {
  local name=$1
  virsh -c qemu:///system autostart "$name" >/dev/null
  if [[ $(virsh -c qemu:///system domstate "$name" 2>/dev/null || true) != running ]]; then
    virsh -c qemu:///system start "$name" >/dev/null
  fi
}

ensure_user_ovmf() {
  local firmware_dir="$STATE_DIR/firmware"
  local download_dir="$firmware_dir/ovmf-download"
  local extract_dir="$firmware_dir/ovmf"
  local code="$extract_dir/usr/share/OVMF/OVMF_CODE_4M.fd"
  local vars="$extract_dir/usr/share/OVMF/OVMF_VARS_4M.fd"
  if [[ ! -f "$code" || ! -f "$vars" ]]; then
    mkdir -p "$download_dir" "$extract_dir"
    (cd "$download_dir" && apt download ovmf-generic >/dev/null)
    dpkg-deb -x "$download_dir"/ovmf-generic_*.deb "$extract_dir"
  fi
  [[ -f "$code" && -f "$vars" ]] || fail "OVMF firmware files not found after download"
  chmod o+x "$HOME" "$HOME/.local" "$HOME/.local/share" "$STATE_DIR" "$firmware_dir" "$extract_dir" "$extract_dir/usr" "$extract_dir/usr/share" "$extract_dir/usr/share/OVMF" 2>/dev/null || true
  chmod o+r "$code" "$vars"
  printf '%s\n%s\n' "$code" "$vars"
}

create_kali_vm() {
  local url base volume seed
  url=$(resolve_dev_image_url)
  base="$IMAGE_DIR/kali-base.qcow2"
  volume="$VOLUME_DIR/kali-dev.qcow2"
  seed="$SEED_DIR/kali-seed.iso"
  download_image "$url" "$base" kali
  create_overlay "$base" "$volume" "$DEV_VM_DISK_GB"
  render_seed kali
  allow_hypervisor_storage_access

  if domain_exists "$DEV_VM_NAME"; then
    log "domain exists: $DEV_VM_NAME"
    ensure_domain_started "$DEV_VM_NAME"
    return
  fi

  mapfile -t ovmf_files < <(ensure_user_ovmf)
  local ovmf_code=${ovmf_files[0]}
  local ovmf_vars=${ovmf_files[1]}

  virt-install \
    --connect qemu:///system \
    --name "$DEV_VM_NAME" \
    --memory "$DEV_VM_MEMORY_MB" \
    --vcpus "$DEV_VM_CPU" \
    --cpu host-passthrough \
    --import \
    --security type=none \
    --boot "loader=$ovmf_code,loader.readonly=yes,loader.type=pflash,nvram.template=$ovmf_vars" \
    --os-variant generic \
    --disk "path=$volume,format=qcow2,bus=virtio" \
    --disk "path=$seed,device=disk,bus=virtio,readonly=on" \
    --network "network=$LAN_NET_NAME,model=virtio,mac=$DEV_LAN_MAC" \
    --graphics vnc,listen=127.0.0.1 \
    --video virtio \
    --noautoconsole
  ensure_domain_started "$DEV_VM_NAME"
}

log "single-VM mode: Kali will use host-scoped transparent gateway ${LAN_HOST_IP}; host egress is not redirected"
ensure_lan_network
if domain_exists "$LEGACY_GW_VM_NAME"; then
  log "removing legacy gateway VM: $LEGACY_GW_VM_NAME"
  if [[ $(virsh -c qemu:///system domstate "$LEGACY_GW_VM_NAME" 2>/dev/null || true) == running ]]; then
    virsh -c qemu:///system destroy "$LEGACY_GW_VM_NAME" >/dev/null || true
  fi
  virsh -c qemu:///system undefine "$LEGACY_GW_VM_NAME" --nvram >/dev/null 2>&1 || virsh -c qemu:///system undefine "$LEGACY_GW_VM_NAME" >/dev/null 2>&1 || true
fi
create_kali_vm
log "waiting for Kali SSH on $DEV_IP:22"
wait_for_tcp "$DEV_IP" 22 120 || fail "Kali SSH did not become reachable from remote host"
log "ready: run make transparent-enable to install host-scoped TProxy; host default egress remains unchanged"
