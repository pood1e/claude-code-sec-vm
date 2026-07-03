#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

HOST_VNC_BIND=${HOST_VNC_BIND:-}
HOST_VNC_PORT=${HOST_VNC_PORT:-5900}
HOST_VNC_ALLOW_CIDR=${HOST_VNC_ALLOW_CIDR:-}
GUEST_VNC_PORT=${GUEST_VNC_PORT:-5901}
RELAY_DIR="$REMOTE_WORKDIR/runtime/vnc-relay"
PID_FILE="$RELAY_DIR/relay.pid"

[[ -n "$HOST_VNC_BIND" ]] || fail "set HOST_VNC_BIND in .env.local before exposing VNC"
[[ -n "$HOST_VNC_ALLOW_CIDR" ]] || fail "set HOST_VNC_ALLOW_CIDR in .env.local before exposing VNC"

remote_script=$(cat <<'REMOTE'
set -euo pipefail
INSTALL_DIR=/usr/local/lib/claude-code-sec-vm
UNIT_FILE=/etc/systemd/system/ccsvm-vnc-forward.service
NFT_TABLE=ccsvm_vnc

require_sudo() {
  if ! sudo_run true >/dev/null 2>&1; then
    echo "remote sudo is required; run this target from an interactive terminal or install the rules manually" >&2
    exit 4
  fi
}

sudo_run() {
  if [ "${ALLOW_INTERACTIVE_SUDO:-0}" = 1 ]; then
    sudo "$@"
  else
    sudo -n "$@"
  fi
}

host_if=$(ip -o -4 addr show | awk -v ip="${HOST_VNC_BIND}" '$4 ~ "^" ip "/" {print $2; exit}')
if [ -z "${host_if}" ]; then
  echo "host bind IP ${HOST_VNC_BIND} is not configured on this host" >&2
  exit 2
fi
if ! bash -c "</dev/tcp/${DEV_IP}/${GUEST_VNC_PORT}" >/dev/null 2>&1; then
  echo "Kali VNC ${DEV_IP}:${GUEST_VNC_PORT} is not reachable; run make vnc-enable first" >&2
  exit 3
fi

require_sudo

tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT

cat >"${tmpdir}/vnc-forward.nft" <<NFT
table ip ${NFT_TABLE} {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "${host_if}" ip saddr ${HOST_VNC_ALLOW_CIDR} ip daddr ${HOST_VNC_BIND} tcp dport ${HOST_VNC_PORT} counter dnat to ${DEV_IP}:${GUEST_VNC_PORT}
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "${LAN_BRIDGE}" ip saddr ${HOST_VNC_ALLOW_CIDR} ip daddr ${DEV_IP} tcp dport ${GUEST_VNC_PORT} counter snat to ${LAN_HOST_IP}
  }

  chain forward {
    type filter hook forward priority -100; policy accept;
    iifname "${host_if}" oifname "${LAN_BRIDGE}" ip saddr ${HOST_VNC_ALLOW_CIDR} ip daddr ${DEV_IP} tcp dport ${GUEST_VNC_PORT} counter accept
    iifname "${LAN_BRIDGE}" oifname "${host_if}" ip saddr ${DEV_IP} ip daddr ${HOST_VNC_ALLOW_CIDR} tcp sport ${GUEST_VNC_PORT} counter accept
  }
}
NFT

cat >"${tmpdir}/vnc-forward-apply.sh" <<APPLY
#!/usr/bin/env bash
set -euo pipefail
NFT_TABLE=ccsvm_vnc
HOST_IF=${host_if}
LAN_BRIDGE=${LAN_BRIDGE}
HOST_VNC_ALLOW_CIDR=${HOST_VNC_ALLOW_CIDR}
DEV_IP=${DEV_IP}
GUEST_VNC_PORT=${GUEST_VNC_PORT}

insert_iptables_rule() {
  iptables -w -C FORWARD "\$@" >/dev/null 2>&1 || iptables -w -I FORWARD 1 "\$@"
}

sysctl -w net.ipv4.ip_forward=1 >/dev/null
if nft list table ip "${NFT_TABLE}" >/dev/null 2>&1; then
  nft delete table ip "${NFT_TABLE}"
fi
nft -f /usr/local/lib/claude-code-sec-vm/vnc-forward.nft
insert_iptables_rule -i "\${HOST_IF}" -o "\${LAN_BRIDGE}" -s "\${HOST_VNC_ALLOW_CIDR}" -d "\${DEV_IP}" -p tcp --dport "\${GUEST_VNC_PORT}" -j ACCEPT
insert_iptables_rule -i "\${LAN_BRIDGE}" -o "\${HOST_IF}" -s "\${DEV_IP}" -d "\${HOST_VNC_ALLOW_CIDR}" -p tcp --sport "\${GUEST_VNC_PORT}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
APPLY

cat >"${tmpdir}/ccsvm-vnc-forward.service" <<UNIT
[Unit]
Description=claude-code-sec-vm VNC kernel forwarding
After=network-online.target libvirtd.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/claude-code-sec-vm/vnc-forward-apply.sh
ExecStop=/bin/sh -c 'while /usr/sbin/iptables -w -D FORWARD -i ${host_if} -o ${LAN_BRIDGE} -s ${HOST_VNC_ALLOW_CIDR} -d ${DEV_IP} -p tcp --dport ${GUEST_VNC_PORT} -j ACCEPT >/dev/null 2>&1; do :; done; while /usr/sbin/iptables -w -D FORWARD -i ${LAN_BRIDGE} -o ${host_if} -s ${DEV_IP} -d ${HOST_VNC_ALLOW_CIDR} -p tcp --sport ${GUEST_VNC_PORT} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1; do :; done; /usr/sbin/nft list table ip ccsvm_vnc >/dev/null 2>&1 && /usr/sbin/nft delete table ip ccsvm_vnc || true'

[Install]
WantedBy=multi-user.target
UNIT

sudo_run install -d -m 0755 "${INSTALL_DIR}"
sudo_run install -m 0644 "${tmpdir}/vnc-forward.nft" "${INSTALL_DIR}/vnc-forward.nft"
sudo_run install -m 0755 "${tmpdir}/vnc-forward-apply.sh" "${INSTALL_DIR}/vnc-forward-apply.sh"
sudo_run install -m 0644 "${tmpdir}/ccsvm-vnc-forward.service" "${UNIT_FILE}"
sudo_run systemctl daemon-reload
sudo_run systemctl enable ccsvm-vnc-forward.service >/dev/null
sudo_run systemctl restart ccsvm-vnc-forward.service

if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" >/dev/null 2>&1; then
  kill "$(cat "${PID_FILE}")" >/dev/null 2>&1 || true
  rm -f "${PID_FILE}"
fi
pkill -f "${REMOTE_WORKDIR}/runtime/vnc-relay.*/tcp_relay.py" >/dev/null 2>&1 || true

printf 'vnc_exposed=%s:%s allow=%s target=%s:%s mode=nft-dnat-snat host_if=%s\n' "${HOST_VNC_BIND}" "${HOST_VNC_PORT}" "${HOST_VNC_ALLOW_CIDR}" "${DEV_IP}" "${GUEST_VNC_PORT}" "${host_if}"
REMOTE
)

tmp_script=$(mktemp)
trap 'rm -f "$tmp_script"' EXIT
printf '%s\n' "$remote_script" >"$tmp_script"

remote_setup="$REMOTE_WORKDIR/runtime/host-vnc-expose-setup.sh"
ssh_remote "mkdir -p $(shell_quote "$REMOTE_WORKDIR/runtime")"
scp "${SSH_OPTS[@]}" "$tmp_script" "$REMOTE_HOST:$remote_setup.tmp" >/dev/null
ssh_remote "mv $(shell_quote "$remote_setup.tmp") $(shell_quote "$remote_setup") && chmod 700 $(shell_quote "$remote_setup")"

interactive_sudo=0
if [[ ${HOST_VNC_INTERACTIVE_SUDO:-auto} == 1 || ( ${HOST_VNC_INTERACTIVE_SUDO:-auto} == auto && -t 0 && -t 1 ) ]]; then
  interactive_sudo=1
fi

ssh_cmd=(ssh "${SSH_OPTS[@]}")
if [[ $interactive_sudo == 1 ]]; then
  ssh_cmd=(ssh -tt "${SSH_OPTS[@]}")
fi

"${ssh_cmd[@]}" "$REMOTE_HOST" \
  "ALLOW_INTERACTIVE_SUDO=$(shell_quote "$interactive_sudo") HOST_VNC_BIND=$(shell_quote "$HOST_VNC_BIND") HOST_VNC_PORT=$(shell_quote "$HOST_VNC_PORT") HOST_VNC_ALLOW_CIDR=$(shell_quote "$HOST_VNC_ALLOW_CIDR") DEV_IP=$(shell_quote "$DEV_IP") GUEST_VNC_PORT=$(shell_quote "$GUEST_VNC_PORT") LAN_BRIDGE=$(shell_quote "$LAN_BRIDGE") LAN_HOST_IP=$(shell_quote "$LAN_HOST_IP") REMOTE_WORKDIR=$(shell_quote "$REMOTE_WORKDIR") RELAY_DIR=$(shell_quote "$RELAY_DIR") PID_FILE=$(shell_quote "$PID_FILE") bash $(shell_quote "$remote_setup")"
