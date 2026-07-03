#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

expected_tz=$(python3 "$ROOT_DIR/scripts/policy_value.py" --policy "$POLICY_FILE" timezone.foreign_clean)
remote_command=$(cat <<'REMOTE'
set -euo pipefail
expected_tz=$1
lan_host_ip=$2
dev_ip=$3

timedatectl set-timezone "$expected_tz"

sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
cat >/etc/sysctl.d/99-ccsvm-kali.conf <<'SYSCTL'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
SYSCTL

rm -f /etc/profile.d/ccsvm-proxy.sh /etc/profile.d/ccsvm-timezone.sh /etc/apt/apt.conf.d/90ccsvm-proxy
systemctl disable --now ccsvm-no-direct-route.service 2>/dev/null || true
rm -f /etc/systemd/system/ccsvm-no-direct-route.service
rm -f /etc/resolv.conf

ensure_user_local_bin_path() {
  local user_name=$1
  local user_home=$2
  local rc_file

  install -d -o "$user_name" -g "$user_name" "$user_home/.local/bin"
  for rc_file in "$user_home/.zshrc" "$user_home/.bashrc"; do
    touch "$rc_file"
    chown "$user_name:$user_name" "$rc_file"
    if ! grep -Fq "claude-code-sec-vm: user-local bin path" "$rc_file"; then
      {
        echo
        echo '# claude-code-sec-vm: user-local bin path'
        echo 'case ":$PATH:" in'
        echo '  *:"$HOME/.local/bin":*) ;;'
        echo '  *) [ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH" ;;'
        echo 'esac'
        echo 'export PATH'
      } >>"$rc_file"
      chown "$user_name:$user_name" "$rc_file"
    fi
  done
}

ensure_user_local_bin_path dev /home/dev
ensure_user_local_bin_path agent /home/agent

ensure_dev_desktop_session_env() {
  local rc_file

  for rc_file in /home/dev/.zshrc /home/dev/.bashrc; do
    touch "$rc_file"
    chown dev:dev "$rc_file"
    if ! grep -Fq "claude-code-sec-vm: attach SSH shell to VNC desktop" "$rc_file"; then
      {
        echo
        echo '# claude-code-sec-vm: attach SSH shell to VNC desktop'
        echo 'if [ -z "${DISPLAY:-}" ] && [ -S /tmp/.X11-unix/X1 ] && [ -r "$HOME/.Xauthority" ]; then'
        echo '  export DISPLAY=:1'
        echo '  export XAUTHORITY="$HOME/.Xauthority"'
        echo '  export XDG_RUNTIME_DIR="/run/user/$(id -u)"'
        echo '  [ -S "$XDG_RUNTIME_DIR/bus" ] && export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"'
        echo '  [ -z "${XDG_CURRENT_DESKTOP:-}" ] && export XDG_CURRENT_DESKTOP=XFCE'
        echo '  [ -z "${DESKTOP_SESSION:-}" ] && export DESKTOP_SESSION=xfce'
        echo '  [ -z "${BROWSER:-}" ] && command -v x-www-browser >/dev/null 2>&1 && export BROWSER=x-www-browser'
        echo 'fi'
      } >>"$rc_file"
      chown dev:dev "$rc_file"
    fi
  done
}

ensure_dev_desktop_session_env

install_browser_privacy_policy() {
  install -d -m 0755 \
    /etc/opt/chrome/policies/managed \
    /etc/chromium/policies/managed \
    /usr/lib/firefox/distribution

  cat >/etc/opt/chrome/policies/managed/ccsvm-privacy.json <<'JSON'
{
  "DefaultGeolocationSetting": 2,
  "WebRtcIPHandling": "disable_non_proxied_udp"
}
JSON
  cp /etc/opt/chrome/policies/managed/ccsvm-privacy.json /etc/chromium/policies/managed/ccsvm-privacy.json

  cat >/usr/lib/firefox/distribution/policies.json <<'JSON'
{
  "policies": {
    "Permissions": {
      "Location": {
        "BlockNewRequests": true
      }
    },
    "Preferences": {
      "geo.enabled": false,
      "media.peerconnection.enabled": false
    }
  }
}
JSON
}

install_browser_privacy_policy

cat >/etc/systemd/system/ccsvm-transparent-client.service <<UNIT
[Unit]
Description=claude-code-sec-vm transparent gateway client route
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip route replace 10.77.0.0/24 dev lan0 src ${dev_ip}
ExecStart=/usr/sbin/ip route replace default via ${lan_host_ip} dev lan0
ExecStart=/bin/sh -c 'echo "nameserver 1.1.1.1" >/etc/resolv.conf; echo "options timeout:2 attempts:2" >>/etc/resolv.conf'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable ccsvm-transparent-client.service >/dev/null
systemctl restart ccsvm-transparent-client.service

systemctl disable --now avahi-daemon 2>/dev/null || true
systemctl disable --now cups 2>/dev/null || true
rm -f /var/run/docker.sock /run/docker.sock 2>/dev/null || true
printf 'kali_transparent_client=enabled default_via=%s proxy_env=removed\n' "$lan_host_ip"
REMOTE
)

exec ssh \
  "${SSH_VM_OPTS[@]}" \
  "dev@$DEV_IP" \
  "sudo -n bash -s -- $(shell_quote "$expected_tz") $(shell_quote "$LAN_HOST_IP") $(shell_quote "$DEV_IP")" <<<"$remote_command"
