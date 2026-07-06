#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/remote/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL_DIR=/usr/local/lib/claude-code-sec-vm
SING_BOX_CONFIG=/etc/claude-code-sec-vm/sing-box.json
SING_BOX_UNIT=/etc/systemd/system/ccsvm-sing-box.service
GATEWAY_UNIT=/etc/systemd/system/ccsvm-transparent-gateway.service
TPROXY_MARK=${TPROXY_MARK:-0x77}
TPROXY_TABLE=${TPROXY_TABLE:-10077}
NFT_TABLE=ccsvm_transparent

sudo_run() {
  if [[ ${ALLOW_INTERACTIVE_SUDO:-0} == 1 ]]; then
    sudo "$@"
  else
    sudo -n "$@"
  fi
}

require_sudo() {
  if ! sudo_run true >/dev/null 2>&1; then
    fail "remote sudo is required; run make transparent-enable from an interactive terminal"
  fi
}

policy_value() {
  python3 "$SRC_DIR/scripts/policy_value.py" --policy "$POLICY_FILE" "$1"
}

blocked_cidrs() {
  PYTHONPATH="$SRC_DIR/scripts" python3 - "$POLICY_FILE" <<'PY'
import sys
from policy import load_policy
items = load_policy(sys.argv[1]).get("blocked_cidrs", [])
print(", ".join(items))
PY
}

flag_enabled() {
  case "${1:-0}" in
    1 | true | TRUE | yes | YES) return 0 ;;
    0 | false | FALSE | no | NO | "") return 1 ;;
    *) fail "invalid boolean value: $1" ;;
  esac
}

install_sing_box() {
  if command -v sing-box >/dev/null 2>&1; then
    return
  fi

  sudo_run apt-get update
  sudo_run apt-get install -y ca-certificates curl
  if sudo_run apt-get install -y sing-box; then
    return
  fi

  local installer
  installer=$(mktemp)
  curl -fsSL --connect-timeout 10 --max-time 120 "$SING_BOX_INSTALL_SCRIPT_URL" -o "$installer"
  sudo_run bash "$installer"
  rm -f "$installer"
  sudo_run apt-get update
  sudo_run apt-get install -y sing-box
}

require_cmd python3 ip nft awk curl systemctl
require_sudo
[[ -f "$OUTBOUNDS_FILE" ]] || fail "missing $OUTBOUNDS_FILE; run make import-xray or create sing-box outbounds first"

host_if=$(ip route show default 0.0.0.0/0 | awk 'NR==1 {for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
[[ -n "$host_if" ]] || fail "cannot determine host default interface"
tproxy_port=$(policy_value tproxy_port)
blocked=$(blocked_cidrs)
lan_access=
if flag_enabled "$ALLOW_KALI_192_168_0_24"; then
  lan_access=192.168.0.0/24
fi

install_sing_box
sing_box_bin=$(command -v sing-box)
[[ -n "$sing_box_bin" ]] || fail "sing-box binary is missing after install"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$RUNTIME_DIR/transparent"

python3 "$SRC_DIR/scripts/render_sing_box_config.py" \
  --policy "$POLICY_FILE" \
  --outbounds "$OUTBOUNDS_FILE" \
  --output "$tmpdir/sing-box.json"

if ! "$sing_box_bin" check -c "$tmpdir/sing-box.json" >"$RUNTIME_DIR/transparent/sing-box-check.log" 2>&1; then
  fail "sing-box config validation failed; inspect remote $RUNTIME_DIR/transparent/sing-box-check.log"
fi

lan_access_set=
lan_access_prerouting_rule=
lan_access_forward_rule=
lan_access_postrouting_chain=
if [[ -n "$lan_access" ]]; then
  lan_access_set=$(cat <<NFT

  set lan_access_v4 {
    type ipv4_addr
    flags interval
    elements = { ${lan_access} }
  }
NFT
)
  lan_access_prerouting_rule="    iifname \"${LAN_BRIDGE}\" ip saddr ${DEV_IP} ip daddr @lan_access_v4 counter accept"
  lan_access_forward_rule="    iifname \"${LAN_BRIDGE}\" ip saddr ${DEV_IP} ip daddr @lan_access_v4 counter accept"
  lan_access_postrouting_chain=$(cat <<NFT

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr ${DEV_IP} ip daddr @lan_access_v4 counter masquerade
  }
NFT
)
fi

cat >"$tmpdir/transparent-gateway.nft" <<NFT
table inet ${NFT_TABLE} {
  set blocked_v4 {
    type ipv4_addr
    flags interval
    elements = { ${blocked} }
  }${lan_access_set}

  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    iifname "${LAN_BRIDGE}" ip saddr ${DEV_IP} ip daddr ${LAN_HOST_IP} ct state established,related counter accept
${lan_access_prerouting_rule}
    iifname "${LAN_BRIDGE}" ip saddr ${DEV_IP} ip daddr @blocked_v4 counter drop
    iifname "${LAN_BRIDGE}" ip saddr ${DEV_IP} meta l4proto { tcp, udp } counter meta mark set ${TPROXY_MARK} tproxy ip to :${tproxy_port} accept
    iifname "${LAN_BRIDGE}" ip saddr ${DEV_IP} counter drop
  }

  chain forward {
    type filter hook forward priority filter; policy accept;
    ct state established,related counter accept
${lan_access_forward_rule}
    iifname "${LAN_BRIDGE}" ip saddr ${DEV_IP} counter drop
  }${lan_access_postrouting_chain}
}
NFT

cat >"$tmpdir/transparent-gateway-apply.sh" <<APPLY
#!/usr/bin/env bash
set -euo pipefail
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.${LAN_BRIDGE}.rp_filter=0 >/dev/null 2>&1 || true
install -D -m 0644 /usr/local/lib/claude-code-sec-vm/transparent-sysctl.conf /etc/sysctl.d/99-ccsvm-transparent.conf
modprobe nf_defrag_ipv4 >/dev/null 2>&1 || true
modprobe nf_tproxy_ipv4 >/dev/null 2>&1 || true
modprobe nft_tproxy >/dev/null 2>&1 || true
ip rule del priority ${TPROXY_TABLE} fwmark ${TPROXY_MARK} table ${TPROXY_TABLE} >/dev/null 2>&1 || true
ip rule add priority ${TPROXY_TABLE} fwmark ${TPROXY_MARK} table ${TPROXY_TABLE}
ip route replace local 0.0.0.0/0 dev lo table ${TPROXY_TABLE}
nft delete table inet ccsvm_transparent >/dev/null 2>&1 || true
nft -f /usr/local/lib/claude-code-sec-vm/transparent-gateway.nft
nft delete table inet ccsvm_host_guard >/dev/null 2>&1 || true
rm -f /etc/nftables.d/ccsvm-host-guard.nft
APPLY

cat >"$tmpdir/transparent-gateway-stop.sh" <<STOP
#!/usr/bin/env bash
set -euo pipefail
nft delete table inet ${NFT_TABLE} >/dev/null 2>&1 || true
ip rule del priority ${TPROXY_TABLE} fwmark ${TPROXY_MARK} table ${TPROXY_TABLE} >/dev/null 2>&1 || true
ip route flush table ${TPROXY_TABLE} >/dev/null 2>&1 || true
STOP

cat >"$tmpdir/transparent-sysctl.conf" <<SYSCTL
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
SYSCTL

cat >"$tmpdir/ccsvm-sing-box.service" <<UNIT
[Unit]
Description=claude-code-sec-vm host-scoped sing-box
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${sing_box_bin} run -c ${SING_BOX_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT

cat >"$tmpdir/ccsvm-transparent-gateway.service" <<UNIT
[Unit]
Description=claude-code-sec-vm host-scoped transparent gateway for Kali VM
After=network-online.target libvirtd.service ccsvm-sing-box.service
Wants=network-online.target ccsvm-sing-box.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${INSTALL_DIR}/transparent-gateway-apply.sh
ExecStop=${INSTALL_DIR}/transparent-gateway-stop.sh

[Install]
WantedBy=multi-user.target
UNIT

sudo_run install -d -m 0755 "$INSTALL_DIR" /etc/claude-code-sec-vm /var/lib/sing-box
sudo_run install -m 0600 "$tmpdir/sing-box.json" "$SING_BOX_CONFIG"
sudo_run install -m 0644 "$tmpdir/transparent-gateway.nft" "$INSTALL_DIR/transparent-gateway.nft"
sudo_run install -m 0755 "$tmpdir/transparent-gateway-apply.sh" "$INSTALL_DIR/transparent-gateway-apply.sh"
sudo_run install -m 0755 "$tmpdir/transparent-gateway-stop.sh" "$INSTALL_DIR/transparent-gateway-stop.sh"
sudo_run install -m 0644 "$tmpdir/transparent-sysctl.conf" "$INSTALL_DIR/transparent-sysctl.conf"
sudo_run install -m 0644 "$tmpdir/ccsvm-sing-box.service" "$SING_BOX_UNIT"
sudo_run install -m 0644 "$tmpdir/ccsvm-transparent-gateway.service" "$GATEWAY_UNIT"

sudo_run systemctl daemon-reload
sudo_run systemctl enable ccsvm-sing-box.service ccsvm-transparent-gateway.service >/dev/null
sudo_run systemctl restart ccsvm-sing-box.service
sudo_run systemctl restart ccsvm-transparent-gateway.service

if [[ -n "$lan_access" ]]; then
  lan_access_status=enabled
else
  lan_access_status=disabled
fi
printf 'transparent_gateway=enabled scope_iif=%s scope_src=%s tproxy_port=%s host_default_if=%s kali_192_168_0_24_access=%s host_output=untouched\n' \
  "$LAN_BRIDGE" "$DEV_IP" "$tproxy_port" "$host_if" "$lan_access_status"
