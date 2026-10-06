"""Render the VM and proxy configuration from one validated local config."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from zoneinfo import available_timezones

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "runtime"
GATEWAY = "10.231.71.1"
GUEST = "10.231.71.2"
MACOS_PROXY = "10.0.2.100"
MAC = "52:54:00:71:00:02"
PROXY_PORT = 10980
PRIVATE = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
BLOCKED = [
    "0.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "192.0.0.0/24",
    "192.0.2.0/24",
    "198.18.0.0/15",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "224.0.0.0/4",
    "240.0.0.0/4",
]


def config() -> dict[str, int | str]:
    path = ROOT / "config.local.json"
    data = json.loads(
        path.read_text() if path.exists() else (ROOT / "config.example.json").read_text()
    )
    expected = {"upstream_socks_port", "timezone", "memory_mib", "vcpus", "disk_gib"}
    if set(data) != expected:
        raise ValueError(f"config keys must be {', '.join(sorted(expected))}")
    for key, low, high in (
        ("upstream_socks_port", 1, 65535),
        ("memory_mib", 4096, 32768),
        ("vcpus", 1, 16),
        ("disk_gib", 20, 256),
    ):
        if type(data[key]) is not int or not low <= data[key] <= high:
            raise ValueError(f"{key} must be an integer in [{low}, {high}]")
    if not isinstance(data["timezone"], str) or data["timezone"] not in available_timezones():
        raise ValueError("timezone must be an IANA timezone")
    return data


def put(path: Path, content: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(mode)


def json_file(path: Path, value: dict) -> None:
    put(path, json.dumps(value, indent=2) + "\n")


def host_proxy(port: int, listen: str) -> dict:
    return {
        "log": {"level": "warn"},
        "dns": {
            "servers": [
                {
                    "type": "https",
                    "tag": "doh",
                    "server": "1.1.1.1",
                    "detour": "upstream",
                }
            ],
            "final": "doh",
            "strategy": "ipv4_only",
        },
        "inbounds": [
            {
                "type": "socks",
                "tag": "guest",
                "listen": listen,
                "listen_port": PROXY_PORT,
            }
        ],
        "outbounds": [
            {
                "type": "socks",
                "tag": "upstream",
                "server": "127.0.0.1",
                "server_port": port,
                "version": "5",
            },
            {"type": "direct", "tag": "private"},
            {"type": "block", "tag": "block"},
        ],
        "route": {
            "rules": [
                {
                    "domain_suffix": [
                        ".localhost",
                        ".local",
                        ".internal",
                        ".home.arpa",
                    ],
                    "outbound": "block",
                },
                {"action": "resolve", "strategy": "ipv4_only"},
                {"ip_version": 6, "outbound": "block"},
                {"ip_cidr": BLOCKED, "outbound": "block"},
                {"ip_cidr": PRIVATE, "outbound": "private"},
            ],
            "final": "upstream",
        },
    }


def guest_proxy(proxy: str, udp_over_tcp: bool = False) -> dict:
    outbound = {
        "type": "socks",
        "tag": "host",
        "server": proxy,
        "server_port": PROXY_PORT,
        "version": "5",
    }
    if udp_over_tcp:
        outbound["udp_over_tcp"] = True
    return {
        "log": {"level": "warn"},
        "dns": {
            "servers": [{"type": "https", "tag": "doh", "server": "1.1.1.1", "detour": "host"}],
            "final": "doh",
            "strategy": "ipv4_only",
        },
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun",
                "interface_name": "claudetun",
                "address": ["172.19.0.1/30"],
                "dns_address": ["172.19.0.2"],
                "auto_route": True,
                "auto_redirect": True,
                "strict_route": True,
                "route_exclude_address": [f"{proxy}/32"],
            }
        ],
        "outbounds": [outbound],
        "route": {
            "auto_detect_interface": True,
            "rules": [
                {"ip_cidr": ["172.19.0.2/32"], "port": 53, "action": "hijack-dns"},
                {"ip_cidr": PRIVATE, "outbound": "host"},
                {"port": 53, "action": "hijack-dns"},
                {"ip_version": 6, "action": "reject"},
                {"ip_cidr": BLOCKED, "action": "reject"},
            ],
            "final": "host",
        },
    }


def render_network() -> str:
    return f"""<network>
  <name>claude-sandbox-net</name>
  <bridge name='virbr-claude' stp='on' delay='0'/>
  <ip address='{GATEWAY}' netmask='255.255.255.0'>
    <dhcp><host mac='{MAC}' name='claude-sandbox' ip='{GUEST}'/></dhcp>
  </ip>
</network>
"""


def render_filter() -> str:
    return f"""<filter name='claude-sandbox-egress' chain='root'>
  <filterref filter='clean-traffic'/>
  <rule action='accept' direction='out' priority='-400'>
    <udp srcportstart='68' dstportstart='67'/>
  </rule>
  <rule action='accept' direction='in' priority='-400'>
    <udp srcportstart='67' dstportstart='68'/>
  </rule>
  <rule action='accept' direction='inout' priority='-300'>
    <all state='ESTABLISHED,RELATED'/>
  </rule>
  <rule action='accept' direction='out' priority='-200'>
    <tcp dstipaddr='{GATEWAY}' dstportstart='{PROXY_PORT}' state='NEW'/>
  </rule>
  <rule action='accept' direction='out' priority='-200'>
    <udp dstipaddr='{GATEWAY}' dstportstart='{PROXY_PORT}' state='NEW'/>
  </rule>
  <rule action='accept' direction='in' priority='-200'>
    <tcp srcipaddr='{GATEWAY}' dstportstart='22' state='NEW'/>
  </rule>
  <rule action='drop' direction='inout' priority='1000'><all/></rule>
</filter>
"""


def render_user_data(key: str) -> str:
    if not key.startswith("ssh-ed25519 ") or "\n" in key:
        raise ValueError("runtime/id_ed25519.pub must contain one Ed25519 key")
    return f"""#cloud-config
hostname: claude-sandbox
manage_etc_hosts: true
ssh_pwauth: false
disable_root: true
users:
  - name: agent
    gecos: Claude Sandbox
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - {json.dumps(key)}
runcmd:
  - [bash, -lc, "mkdir -p /mnt/claude-tools && mount -L CLAUDETOOLS /mnt/claude-tools && bash /mnt/claude-tools/bootstrap.sh"]
"""


def render_bootstrap(timezone: str) -> str:
    return f"""#!/usr/bin/env bash
set -euo pipefail
install -m 0755 /mnt/claude-tools/sing-box /usr/local/bin/sing-box
install -D -m 0644 /mnt/claude-tools/guest.json /etc/claude-sandbox/sing-box.json
install -D -m 0644 /mnt/claude-tools/guest.service /etc/systemd/system/claude-sandbox-net.service
timedatectl set-timezone {timezone}
systemctl disable --now systemd-resolved
rm -f /etc/resolv.conf
printf 'nameserver 172.19.0.2\\noptions timeout:2 attempts:2\\n' >/etc/resolv.conf
systemctl daemon-reload
sing-box check -c /etc/claude-sandbox/sing-box.json
systemctl enable --now claude-sandbox-net.service
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git jq openssh-server
systemctl enable --now ssh
for rc in /home/agent/.profile /home/agent/.bashrc; do
  printf '\\nexport PATH="$HOME/.local/bin:$PATH"\\n' >>"$rc"
  chown agent:agent "$rc"
done
install -d -m 0700 -o agent -g agent /home/agent/.claude
cat >/home/agent/.claude/settings.json <<'JSON'
{{
  "autoUpdatesChannel": "stable",
  "env": {{
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "DISABLE_FEEDBACK_COMMAND": "1",
    "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL": "1"
  }},
  "skipWebFetchPreflight": true
}}
JSON
chown agent:agent /home/agent/.claude/settings.json
chmod 0600 /home/agent/.claude/settings.json
curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh
chmod 0755 /tmp/claude-install.sh
runuser -u agent -- bash -lc 'bash /tmp/claude-install.sh stable'
runuser -u agent -- /home/agent/.local/bin/claude --version
touch /var/lib/claude-sandbox-ready
"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=("linux", "macos"), default="linux")
    parser.add_argument("--validate", action="store_true")
    args = parser.parse_args()
    cfg = config()
    if args.validate:
        return
    key = (RUNTIME / "id_ed25519.pub").read_text().strip()
    if args.platform == "linux":
        put(RUNTIME / "network.xml", render_network())
        put(RUNTIME / "filter.xml", render_filter())
    listen, proxy = (GATEWAY, GATEWAY) if args.platform == "linux" else ("127.0.0.1", MACOS_PROXY)
    json_file(RUNTIME / "host.json", host_proxy(cfg["upstream_socks_port"], listen))
    json_file(RUNTIME / "iso" / "guest.json", guest_proxy(proxy, args.platform == "macos"))
    put(RUNTIME / "user-data", render_user_data(key), 0o600)
    put(RUNTIME / "seed" / "user-data", render_user_data(key), 0o600)
    put(
        RUNTIME / "seed" / "meta-data",
        "instance-id: claude-sandbox-001\nlocal-hostname: claude-sandbox\n",
    )
    put(RUNTIME / "iso" / "bootstrap.sh", render_bootstrap(cfg["timezone"]), 0o755)
    put(
        RUNTIME / "iso" / "guest.service",
        """[Unit]
Description=Claude sandbox guest tunnel
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/claude-sandbox/sing-box.json
Restart=always
RestartSec=3
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW

[Install]
WantedBy=multi-user.target
""",
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        sys.exit(str(exc))
