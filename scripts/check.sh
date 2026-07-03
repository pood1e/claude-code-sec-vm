#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

while IFS= read -r script; do
  bash -n "$script"
done < <(find scripts -type f -name '*.sh' | sort)

python3 -m compileall -q scripts
while IFS= read -r json_file; do
  python3 -m json.tool "$json_file" >/dev/null
done < <(find config/examples -type f -name '*.json' | sort)

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE test@example' >"$tmp_dir/key.pub"
cat >"$tmp_dir/xray.json" <<'JSON'
{
  "inbounds": [
    {"tag": "ldc-http", "protocol": "http", "port": 10811}
  ],
  "routing": {
    "rules": [
      {"type": "field", "inboundTag": ["ldc-http"], "outboundTag": "ldc"}
    ]
  },
  "outbounds": [
    {
      "tag": "ldc",
      "protocol": "shadowsocks",
      "settings": {"servers": [{"address": "ss.example.test", "port": 8388, "method": "aes-128-gcm", "password": "example-password"}]},
      "streamSettings": {"network": "tcp"},
      "proxySettings": {"tag": "LOS"}
    },
    {
      "tag": "LOS",
      "protocol": "vless",
      "settings": {"vnext": [{"address": "vless.example.test", "port": 443, "users": [{"id": "00000000-0000-4000-8000-000000000000", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
      "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"serverName": "www.example.com", "fingerprint": "chrome", "publicKey": "example-public-key", "shortId": "abcd"}}
    }
  ]
}
JSON
python3 scripts/import_xray_outbounds.py   --source "$tmp_dir/xray.json"   --output "$tmp_dir/imported-outbounds.json" >/dev/null
python3 scripts/render_sing_box_config.py   --policy config/egress.policy.yaml   --outbounds "$tmp_dir/imported-outbounds.json"   --output "$tmp_dir/imported-sing-box.json"
python3 scripts/render_sing_box_config.py \
  --policy config/egress.policy.yaml \
  --outbounds config/examples/sing-box-outbounds.local.example.json \
  --output "$tmp_dir/sing-box.json"
python3 scripts/render_cloud_init.py \
  --role kali \
  --authorized-key-file "$tmp_dir/key.pub" \
  --user-data "$tmp_dir/kali-user-data.yaml" \
  --network-config "$tmp_dir/kali-network.yaml" \
  --lan-host-ip 10.77.0.254 \
  --dev-ip 10.77.0.10 \
  --dev-lan-mac 52:54:00:77:00:10 \
  --timezone America/Los_Angeles

echo "check passed"
