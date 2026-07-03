#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

expected_tz=$(python3 "$ROOT_DIR/scripts/policy_value.py" --policy "$POLICY_FILE" timezone.foreign_clean)
remote_command=$(cat <<'REMOTE'
set -euo pipefail
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$*"; }

actual_tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
[ "$actual_tz" = "$EXPECTED_TZ" ] || fail "timezone=$actual_tz expected=$EXPECTED_TZ"
ok "timezone $actual_tz"

ip route | grep -Eq "^default via ${LAN_HOST_IP//./\\.} dev lan0" || fail "default route is not via transparent host gateway $LAN_HOST_IP"
ok "default route via transparent host gateway"

if printenv | grep -Eiq '^(all|http|https|no)_proxy=|^(ALL|HTTP|HTTPS|NO)_PROXY='; then
  fail "proxy environment variables are present"
fi
ok "no proxy environment variables"

[ ! -e /etc/profile.d/ccsvm-proxy.sh ] || fail "legacy proxy profile still exists"
[ ! -e /etc/apt/apt.conf.d/90ccsvm-proxy ] || fail "legacy apt proxy still exists"
ok "legacy explicit proxy config absent"

python3 - <<'PY'
import os
import urllib.request

for key in list(os.environ):
    if key.lower().endswith("_proxy"):
        os.environ.pop(key, None)
request = urllib.request.Request(os.environ["FOREIGN_CHECK_URL"], method="GET")
with urllib.request.urlopen(request, timeout=25) as response:
    body = response.read(4096).decode("utf-8", "replace")
    if response.status >= 400:
        raise SystemExit(f"unexpected status: {response.status}")
    if "ip=" not in body:
        raise SystemExit("trace response missing ip")
PY
ok "HTTPS works without explicit proxy"

if timeout 3 bash -c '</dev/tcp/169.254.169.254/80' >/dev/null 2>&1; then
  fail "metadata endpoint reachable"
fi
ok "metadata endpoint blocked"

if timeout 3 bash -c "</dev/tcp/$LAN_HOST_IP/22" >/dev/null 2>&1; then
  fail "host private SSH endpoint reachable as a new VM connection"
fi
ok "host/private endpoints blocked for new VM connections"

[ ! -S /var/run/docker.sock ] && [ ! -S /run/docker.sock ] || fail "Docker socket visible"
ok "Docker socket absent"

if sudo -n -u agent sudo -n true >/dev/null 2>&1; then
  fail "agent user has sudo"
fi
ok "agent has no sudo"

python3 - <<'PY'
import json
from pathlib import Path

chrome_policy = Path("/etc/opt/chrome/policies/managed/ccsvm-privacy.json")
if not chrome_policy.is_file():
    raise SystemExit("missing Chrome privacy policy")
chrome = json.loads(chrome_policy.read_text(encoding="utf-8"))
if chrome.get("WebRtcIPHandling") != "disable_non_proxied_udp":
    raise SystemExit("Chrome WebRTC policy is not locked down")
if chrome.get("DefaultGeolocationSetting") != 2:
    raise SystemExit("Chrome geolocation policy is not blocked")

firefox_policy = Path("/usr/lib/firefox/distribution/policies.json")
if not firefox_policy.is_file():
    raise SystemExit("missing Firefox privacy policy")
firefox = json.loads(firefox_policy.read_text(encoding="utf-8")).get("policies", {})
prefs = firefox.get("Preferences", {})
if prefs.get("media.peerconnection.enabled") is not False:
    raise SystemExit("Firefox WebRTC is not disabled")
if prefs.get("geo.enabled") is not False:
    raise SystemExit("Firefox geolocation is not disabled")
PY
ok "browser WebRTC/geolocation policies locked down"
REMOTE
)

exec ssh \
  -J "$REMOTE_HOST" \
  -o ConnectTimeout=8 \
  -o ServerAliveInterval=5 \
  -o ServerAliveCountMax=2 \
  -o ForwardAgent=no \
  -o ClearAllForwardings=yes \
  -o UserKnownHostsFile=/tmp/ccsvm-known-hosts \
  -o StrictHostKeyChecking=accept-new \
  "dev@$DEV_IP" \
  "EXPECTED_TZ=$(shell_quote "$expected_tz") LAN_HOST_IP=$(shell_quote "$LAN_HOST_IP") FOREIGN_CHECK_URL=$(shell_quote "$FOREIGN_CHECK_URL") bash -s" <<<"$remote_command"
