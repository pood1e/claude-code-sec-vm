#!/usr/bin/env python3
"""Tiny policy parser for config/egress.policy.yaml.

The repository intentionally avoids a PyYAML dependency. This parser supports only
this repo's committed policy shape: top-level scalars, one-level maps and lists.
"""
from __future__ import annotations

from pathlib import Path
from typing import Any


def _strip_comment(line: str) -> str:
    in_quote = False
    quote_char = ""
    for idx, char in enumerate(line):
        if char in {'"', "'"}:
            if not in_quote:
                in_quote = True
                quote_char = char
            elif quote_char == char:
                in_quote = False
        if char == "#" and not in_quote:
            return line[:idx]
    return line


def _scalar(value: str) -> Any:
    value = value.strip()
    if not value:
        return ""
    if value[0:1] == value[-1:] and value[0:1] in {'"', "'"}:
        return value[1:-1]
    if value.lower() == "true":
        return True
    if value.lower() == "false":
        return False
    try:
        return int(value)
    except ValueError:
        return value


def load_policy(path: str | Path) -> dict[str, Any]:
    result: dict[str, Any] = {}
    current_key: str | None = None
    current_is_list = False

    for line_number, raw_line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), start=1):
        line = _strip_comment(raw_line).rstrip()
        if not line.strip():
            continue

        if not line.startswith(" "):
            if ":" not in line:
                raise ValueError(f"invalid policy line {line_number}: {raw_line}")
            key, raw_value = line.split(":", 1)
            key = key.strip()
            raw_value = raw_value.strip()
            if raw_value:
                result[key] = _scalar(raw_value)
                current_key = None
                current_is_list = False
            else:
                result[key] = {}
                current_key = key
                current_is_list = False
            continue

        if current_key is None:
            raise ValueError(f"indented value without section at line {line_number}")

        item = line.strip()
        if item.startswith("- "):
            if not current_is_list:
                result[current_key] = []
                current_is_list = True
            result[current_key].append(_scalar(item[2:]))
            continue

        if ":" not in item:
            raise ValueError(f"invalid nested policy line {line_number}: {raw_line}")
        key, raw_value = item.split(":", 1)
        if current_is_list:
            raise ValueError(f"cannot mix list and map in section {current_key}")
        result[current_key][key.strip()] = _scalar(raw_value)

    return result


def require_string(policy: dict[str, Any], *path: str) -> str:
    value: Any = policy
    for key in path:
        if not isinstance(value, dict) or key not in value:
            raise KeyError(".".join(path))
        value = value[key]
    if not isinstance(value, str) or not value:
        raise ValueError(f"policy value {'.'.join(path)} must be a non-empty string")
    return value


def require_int(policy: dict[str, Any], *path: str) -> int:
    value: Any = policy
    for key in path:
        if not isinstance(value, dict) or key not in value:
            raise KeyError(".".join(path))
        value = value[key]
    if not isinstance(value, int):
        raise ValueError(f"policy value {'.'.join(path)} must be an integer")
    return value
