#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

FOREIGN_TIMEZONE_URL=${FOREIGN_TIMEZONE_URL:-https://ipapi.co/json/}

detect_remote_timezone() {
  local remote_command
  remote_command=$(cat <<'REMOTE'
set -euo pipefail
timezone_url=$1

python3 - "$timezone_url" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
import urllib.request
from typing import Any
from zoneinfo import ZoneInfo

TIMEOUT_SECONDS = 20
TIMEZONE_PATTERN = re.compile(r"^[A-Za-z_]+/[A-Za-z0-9_+.-]+(?:/[A-Za-z0-9_+.-]+)?$")


def fail(message: str) -> None:
    raise SystemExit(message)


def nested_string(data: dict[str, Any], *path: str) -> str | None:
    value: Any = data
    for segment in path:
        if not isinstance(value, dict) or segment not in value:
            return None
        value = value[segment]
    return value if isinstance(value, str) and value else None


def detect_timezone(body: str, content_type: str) -> str:
    stripped = body.strip()
    data: Any | None = None
    if "json" in content_type.lower() or stripped.startswith("{"):
        try:
            data = json.loads(stripped)
        except json.JSONDecodeError as exc:
            fail(f"invalid timezone JSON response: {exc}")
    if isinstance(data, dict):
        for path in (
            ("timezone",),
            ("time_zone", "id"),
            ("timezone", "id"),
            ("location", "time_zone"),
            ("tz",),
            ("timeZone",),
        ):
            value = nested_string(data, *path)
            if value:
                return value
        fail("timezone response does not contain a timezone field")
    return stripped


def validate_timezone(value: str) -> str:
    value = value.strip()
    if not TIMEZONE_PATTERN.fullmatch(value):
        fail(f"invalid timezone value: {value!r}")
    try:
        ZoneInfo(value)
    except Exception as exc:  # noqa: BLE001 - keep VM-side failure concise.
        fail(f"unknown timezone {value!r}: {exc}")
    return value


for key in list(os.environ):
    if key.lower().endswith("_proxy"):
        os.environ.pop(key, None)

request = urllib.request.Request(
    sys.argv[1],
    headers={"User-Agent": "claude-code-sec-vm/foreign-clean-refresh"},
    method="GET",
)
with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
    content_type = response.headers.get("Content-Type", "")
    body = response.read(65536).decode("utf-8", "replace")
    if response.status >= 400:
        fail(f"timezone endpoint returned HTTP {response.status}")

print(validate_timezone(detect_timezone(body, content_type)))
PY
REMOTE
)

  ssh \
    "${SSH_VM_OPTS[@]}" \
    "dev@$DEV_IP" \
    "bash -s -- $(shell_quote "$FOREIGN_TIMEZONE_URL")" <<<"$remote_command"
}

update_policy_timezone() {
  local timezone=$1
  python3 - "$POLICY_FILE" "$timezone" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
new_timezone = sys.argv[2]
text = path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)

in_timezone = False
updated = False
old_timezone = ""
for index, line in enumerate(lines):
    if re.match(r"^timezone:\s*(?:#.*)?$", line):
        in_timezone = True
        continue
    if in_timezone and line and not line.startswith(" "):
        in_timezone = False
    if in_timezone:
        match = re.match(r"^(\s*foreign_clean:\s*)(\S+)(\s*(?:#.*)?)(\n?)$", line)
        if match:
            old_timezone = match.group(2)
            lines[index] = f"{match.group(1)}{new_timezone}{match.group(3)}{match.group(4)}"
            updated = True
            break

if not updated:
    raise SystemExit("missing policy value: timezone.foreign_clean")

path.write_text("".join(lines), encoding="utf-8")
print(f"{old_timezone}->{new_timezone}")
PY
}

current_timezone=$(python3 "$ROOT_DIR/scripts/policy_value.py" --policy "$POLICY_FILE" timezone.foreign_clean)
detected_timezone=$(detect_remote_timezone | tail -n 1)
change=$(update_policy_timezone "$detected_timezone")

printf 'foreign_clean_timezone=%s\n' "$change"
if [[ "$current_timezone" == "$detected_timezone" ]]; then
  printf 'policy=unchanged\n'
else
  printf 'policy=updated\n'
fi

bash "$ROOT_DIR/scripts/kali-transparent-enable.sh"
bash "$ROOT_DIR/scripts/egress-check.sh"
