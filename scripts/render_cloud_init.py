#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import textwrap
from pathlib import Path


def indent(text: str, spaces: int = 6) -> str:
    prefix = " " * spaces
    return "\n".join(prefix + line if line else prefix for line in text.splitlines())


def b64_block(data: bytes, width: int = 76) -> str:
    encoded = base64.b64encode(data).decode("ascii")
    return "\n".join(encoded[index : index + width] for index in range(0, len(encoded), width))


def kali_hardening_script(timezone: str, lan_host_ip: str, dev_ip: str) -> str:
    return f"""#!/usr/bin/env bash
set -euo pipefail

timedatectl set-timezone {timezone!r}

sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
cat >/etc/sysctl.d/99-ccsvm-kali.conf <<'SYSCTL'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
SYSCTL

rm -f /etc/profile.d/ccsvm-proxy.sh /etc/profile.d/ccsvm-timezone.sh /etc/apt/apt.conf.d/90ccsvm-proxy
rm -f /etc/resolv.conf
systemctl disable --now ccsvm-no-direct-route.service 2>/dev/null || true
rm -f /etc/systemd/system/ccsvm-no-direct-route.service

ensure_user_local_bin_path() {{
  local user_name=$1
  local user_home=$2
  local rc_file

  install -d -o "$user_name" -g "$user_name" "$user_home/.local/bin"
  for rc_file in "$user_home/.zshrc" "$user_home/.bashrc"; do
    touch "$rc_file"
    chown "$user_name:$user_name" "$rc_file"
    if ! grep -Fq "claude-code-sec-vm: user-local bin path" "$rc_file"; then
      {{
        echo
        echo '# claude-code-sec-vm: user-local bin path'
        echo 'case ":$PATH:" in'
        echo '  *:"$HOME/.local/bin":*) ;;'
        echo '  *) [ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH" ;;'
        echo 'esac'
        echo 'export PATH'
      }} >>"$rc_file"
      chown "$user_name:$user_name" "$rc_file"
    fi
  done
}}

ensure_user_local_bin_path dev /home/dev
ensure_user_local_bin_path agent /home/agent

ensure_dev_desktop_session_env() {{
  local rc_file

  for rc_file in /home/dev/.zshrc /home/dev/.bashrc; do
    touch "$rc_file"
    chown dev:dev "$rc_file"
    if ! grep -Fq "claude-code-sec-vm: attach SSH shell to VNC desktop" "$rc_file"; then
      {{
        echo
        echo '# claude-code-sec-vm: attach SSH shell to VNC desktop'
        echo 'if [ -z "${{DISPLAY:-}}" ] && [ -S /tmp/.X11-unix/X1 ] && [ -r "$HOME/.Xauthority" ]; then'
        echo '  export DISPLAY=:1'
        echo '  export XAUTHORITY="$HOME/.Xauthority"'
        echo '  export XDG_RUNTIME_DIR="/run/user/$(id -u)"'
        echo '  [ -S "$XDG_RUNTIME_DIR/bus" ] && export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"'
        echo '  [ -z "${{XDG_CURRENT_DESKTOP:-}}" ] && export XDG_CURRENT_DESKTOP=XFCE'
        echo '  [ -z "${{DESKTOP_SESSION:-}}" ] && export DESKTOP_SESSION=xfce'
        echo '  [ -z "${{BROWSER:-}}" ] && command -v x-www-browser >/dev/null 2>&1 && export BROWSER=x-www-browser'
        echo 'fi'
      }} >>"$rc_file"
      chown dev:dev "$rc_file"
    fi
  done
}}

ensure_dev_desktop_session_env

install_browser_privacy_policy() {{
  install -d -m 0755 \\
    /etc/opt/chrome/policies/managed \\
    /etc/chromium/policies/managed \\
    /usr/lib/firefox/distribution

  cat >/etc/opt/chrome/policies/managed/ccsvm-privacy.json <<'JSON'
{{
  "DefaultGeolocationSetting": 2,
  "WebRtcIPHandling": "disable_non_proxied_udp"
}}
JSON
  cp /etc/opt/chrome/policies/managed/ccsvm-privacy.json /etc/chromium/policies/managed/ccsvm-privacy.json

  cat >/usr/lib/firefox/distribution/policies.json <<'JSON'
{{
  "policies": {{
    "Permissions": {{
      "Location": {{
        "BlockNewRequests": true
      }}
    }},
    "Preferences": {{
      "geo.enabled": false,
      "media.peerconnection.enabled": false
    }}
  }}
}}
JSON
}}

install_browser_privacy_policy

cat >/etc/systemd/system/ccsvm-transparent-client.service <<'UNIT'
[Unit]
Description=claude-code-sec-vm transparent gateway client route
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip route replace 10.77.0.0/24 dev lan0 src {dev_ip}
ExecStart=/usr/sbin/ip route replace default via {lan_host_ip} dev lan0
ExecStart=/bin/sh -c 'echo "nameserver 1.1.1.1" >/etc/resolv.conf; echo "options timeout:2 attempts:2" >>/etc/resolv.conf'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now ccsvm-transparent-client.service

systemctl disable --now avahi-daemon 2>/dev/null || true
systemctl disable --now cups 2>/dev/null || true
rm -f /var/run/docker.sock /run/docker.sock 2>/dev/null || true
"""


def write_b64_file(path: str, mode: str, content: bytes) -> str:
    return textwrap.dedent(
        f"""
          - path: {path}
            owner: root:root
            permissions: '{mode}'
            encoding: b64
            content: |
        """
    ).rstrip() + "\n" + indent(b64_block(content), 14)


def render_kali(args: argparse.Namespace, authorized_key: str) -> tuple[str, str]:
    hardening = kali_hardening_script(args.timezone, args.lan_host_ip, args.dev_ip)
    user_data = f"""#cloud-config
hostname: kali-dev
manage_etc_hosts: true
ssh_pwauth: false
users:
  - name: dev
    gecos: Human Developer
    groups: sudo
    shell: /usr/bin/zsh
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - {authorized_key}
  - name: agent
    gecos: Isolated Agent Runtime
    shell: /usr/bin/zsh
    lock_passwd: true
    ssh_authorized_keys:
      - {authorized_key}
package_update: true
packages:
  - ca-certificates
  - curl
  - git
  - jq
  - tmux
  - zsh
  - neovim
  - build-essential
  - python3
  - python3-pip
  - python3-venv
  - nodejs
  - npm
  - golang-go
  - rustc
  - cargo
write_files:
{write_b64_file('/usr/local/sbin/ccsvm-kali-hardening.sh', '0755', hardening.encode())}
runcmd:
  - [ bash, /usr/local/sbin/ccsvm-kali-hardening.sh ]
"""
    network_config = f"""version: 2
ethernets:
  lan0:
    match:
      macaddress: {args.dev_lan_mac}
    set-name: lan0
    dhcp4: false
    dhcp6: false
    addresses:
      - {args.dev_ip}/24
    routes:
      - to: 0.0.0.0/0
        via: {args.lan_host_ip}
    nameservers:
      addresses:
        - 1.1.1.1
"""
    return user_data, network_config


def main() -> None:
    parser = argparse.ArgumentParser(description="Render Kali cloud-init user-data and network-config")
    parser.add_argument("--role", choices=["kali"], required=True)
    parser.add_argument("--authorized-key-file", required=True, type=Path)
    parser.add_argument("--user-data", required=True, type=Path)
    parser.add_argument("--network-config", required=True, type=Path)
    parser.add_argument("--lan-host-ip", required=True)
    parser.add_argument("--dev-ip", required=True)
    parser.add_argument("--dev-lan-mac", required=True)
    parser.add_argument("--timezone", required=True)
    args = parser.parse_args()

    authorized_key = args.authorized_key_file.read_text(encoding="utf-8").strip()
    if not authorized_key:
        raise SystemExit("authorized key file is empty")

    user_data, network_config = render_kali(args, authorized_key)

    args.user_data.parent.mkdir(parents=True, exist_ok=True)
    args.network_config.parent.mkdir(parents=True, exist_ok=True)
    args.user_data.write_text(user_data, encoding="utf-8")
    args.network_config.write_text(network_config, encoding="utf-8")
    args.user_data.chmod(0o600)
    args.network_config.chmod(0o600)


if __name__ == "__main__":
    main()
