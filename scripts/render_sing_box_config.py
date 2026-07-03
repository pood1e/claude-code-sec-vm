#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from policy import load_policy, require_int, require_string  # noqa: E402

REQUIRED_OUTBOUND_TAGS = {"domestic", "foreign_clean"}


def load_outbounds(path: Path) -> list[dict[str, Any]]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(raw, dict):
        raw = raw.get("outbounds")
    if not isinstance(raw, list):
        raise SystemExit("sing-box outbounds file must be a JSON array or an object with outbounds[]")

    tags: set[str] = set()
    for outbound in raw:
        if not isinstance(outbound, dict):
            raise SystemExit("each outbound must be a JSON object")
        tag = outbound.get("tag")
        if not isinstance(tag, str) or not tag:
            raise SystemExit("each outbound must have a non-empty tag")
        if tag in tags:
            raise SystemExit(f"duplicate outbound tag: {tag}")
        tags.add(tag)

    missing = REQUIRED_OUTBOUND_TAGS - tags
    if missing:
        raise SystemExit(f"missing required outbound tags: {', '.join(sorted(missing))}")
    if "block" in tags:
        raise SystemExit("outbounds file must not define reserved tag: block")
    return raw


def build_config(policy: dict[str, Any], outbounds: list[dict[str, Any]]) -> dict[str, Any]:
    default_outbound = require_string(policy, "default_outbound")
    tproxy_port = require_int(policy, "tproxy_port")
    force_foreign_clean = bool(policy.get("force_foreign_clean", False))

    if default_outbound not in REQUIRED_OUTBOUND_TAGS:
        raise SystemExit("default_outbound must be domestic or foreign_clean")
    if force_foreign_clean and default_outbound != "foreign_clean":
        raise SystemExit("force_foreign_clean requires default_outbound=foreign_clean")

    dns_servers = [
        {
            "type": "udp",
            "tag": "bootstrap-dns",
            "server": "1.1.1.1",
        },
        {
            "type": "https",
            "tag": "foreign-dns",
            "server": "1.1.1.1",
            "path": "/dns-query",
            "detour": "foreign_clean",
        },
    ]
    dns_rules: list[dict[str, Any]] = []
    route_rules: list[dict[str, Any]] = [
        {
            "action": "sniff",
            "timeout": "1s",
        },
        {
            "port": 53,
            "action": "hijack-dns",
        },
        {
            "ip_is_private": True,
            "action": "route",
            "outbound": "block",
        },
    ]
    route_sets: list[dict[str, Any]] = []

    if not force_foreign_clean:
        geosite_cn = require_string(policy, "route_sets", "geosite_cn")
        geoip_cn = require_string(policy, "route_sets", "geoip_cn")
        dns_servers.insert(
            0,
            {
                "type": "https",
                "tag": "domestic-dns",
                "server": "223.5.5.5",
                "path": "/dns-query",
                "detour": "domestic",
            },
        )
        dns_rules.append({"rule_set": "geosite-cn", "action": "route", "server": "domestic-dns"})
        route_rules.append({"rule_set": ["geosite-cn", "geoip-cn"], "action": "route", "outbound": "domestic"})
        route_sets.extend(
            [
                {
                    "tag": "geosite-cn",
                    "type": "remote",
                    "format": "binary",
                    "url": geosite_cn,
                    "download_detour": "foreign_clean",
                },
                {
                    "tag": "geoip-cn",
                    "type": "remote",
                    "format": "binary",
                    "url": geoip_cn,
                    "download_detour": "foreign_clean",
                },
            ]
        )

    route: dict[str, Any] = {
        "auto_detect_interface": True,
        "default_domain_resolver": "bootstrap-dns",
        "rules": route_rules,
        "final": default_outbound,
    }
    if route_sets:
        route["rule_set"] = route_sets

    return {
        "log": {
            "level": "warn",
            "timestamp": True,
        },
        "dns": {
            "servers": dns_servers,
            "rules": dns_rules,
            "final": "foreign-dns",
            "strategy": "ipv4_only",
        },
        "inbounds": [
            {
                "type": "tproxy",
                "tag": "lan-tproxy",
                "listen": "0.0.0.0",
                "listen_port": tproxy_port,
            },
            {
                "type": "mixed",
                "tag": "local-debug-proxy",
                "listen": "127.0.0.1",
                "listen_port": 7890,
            },
        ],
        "outbounds": [*outbounds, {"type": "block", "tag": "block"}],
        "route": route,
        "experimental": {
            "cache_file": {
                "enabled": True,
                "path": "/var/lib/sing-box/cache.db",
            }
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Render gateway sing-box config without leaking outbounds")
    parser.add_argument("--policy", required=True, type=Path)
    parser.add_argument("--outbounds", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    policy = load_policy(args.policy)
    outbounds = load_outbounds(args.outbounds)
    config = build_config(policy, outbounds)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(config, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    args.output.chmod(0o600)


if __name__ == "__main__":
    main()
