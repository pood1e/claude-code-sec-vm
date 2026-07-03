#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
from typing import Any

SUPPORTED_PROTOCOLS = {"freedom", "http", "shadowsocks", "socks", "vless"}


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def find_inbound_tag(config: dict[str, Any], inbound_port: int, inbound_tag: str | None) -> str:
    if inbound_tag:
        return inbound_tag
    matches = [inbound for inbound in config.get("inbounds", []) if str(inbound.get("port")) == str(inbound_port)]
    if not matches:
        fail(f"no Xray inbound found for port {inbound_port}")
    if len(matches) > 1:
        fail(f"multiple Xray inbounds found for port {inbound_port}; pass --inbound-tag")
    tag = matches[0].get("tag")
    if not tag:
        fail(f"Xray inbound on port {inbound_port} has no tag")
    return tag


def find_routed_outbound_tag(config: dict[str, Any], inbound_tag: str) -> str:
    for rule in config.get("routing", {}).get("rules", []):
        inbound_tags = rule.get("inboundTag") or []
        if inbound_tag in inbound_tags:
            outbound_tag = rule.get("outboundTag")
            if not outbound_tag:
                fail(f"routing rule for inbound {inbound_tag} has no outboundTag")
            return outbound_tag
    fail(f"no routing rule found for inbound tag {inbound_tag}")


def outbounds_by_tag(config: dict[str, Any]) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for outbound in config.get("outbounds", []):
        tag = outbound.get("tag")
        if not tag:
            continue
        if tag in result:
            fail(f"duplicate Xray outbound tag: {tag}")
        result[tag] = outbound
    return result


def resolve_chain(selected_tag: str, by_tag: dict[str, dict[str, Any]]) -> list[str]:
    chain: list[str] = []
    seen: set[str] = set()
    tag: str | None = selected_tag
    while tag:
        if tag in seen:
            fail(f"proxySettings cycle detected at outbound tag {tag}")
        seen.add(tag)
        outbound = by_tag.get(tag)
        if outbound is None:
            fail(f"proxySettings references missing outbound tag {tag}")
        protocol = outbound.get("protocol")
        if protocol not in SUPPORTED_PROTOCOLS:
            fail(f"unsupported Xray outbound protocol {protocol!r} at tag {tag}")
        chain.append(tag)
        tag = (outbound.get("proxySettings") or {}).get("tag")
    return chain


def first_item(items: Any, label: str) -> dict[str, Any]:
    if not isinstance(items, list) or len(items) != 1 or not isinstance(items[0], dict):
        fail(f"{label} must contain exactly one object")
    return items[0]


def copy_if_present(source: dict[str, Any], source_key: str, target: dict[str, Any], target_key: str) -> None:
    value = source.get(source_key)
    if value not in (None, ""):
        target[target_key] = value


def convert_transport(stream: dict[str, Any], target: dict[str, Any]) -> None:
    network = stream.get("network", "tcp")
    if network in (None, "tcp"):
        return
    if network == "ws":
        ws = stream.get("wsSettings") or {}
        transport: dict[str, Any] = {"type": "ws"}
        copy_if_present(ws, "path", transport, "path")
        headers = ws.get("headers")
        if headers:
            transport["headers"] = headers
        target["transport"] = transport
        return
    if network == "grpc":
        grpc = stream.get("grpcSettings") or {}
        transport = {"type": "grpc"}
        copy_if_present(grpc, "serviceName", transport, "service_name")
        target["transport"] = transport
        return
    fail(f"unsupported Xray stream network {network!r}")


def convert_tls(stream: dict[str, Any], target: dict[str, Any]) -> None:
    security = stream.get("security")
    if security in (None, "", "none"):
        return

    if security == "tls":
        tls_settings = stream.get("tlsSettings") or {}
        tls: dict[str, Any] = {"enabled": True}
        copy_if_present(tls_settings, "serverName", tls, "server_name")
        fingerprint = tls_settings.get("fingerprint")
        if fingerprint:
            tls["utls"] = {"enabled": True, "fingerprint": fingerprint}
        target["tls"] = tls
        return

    if security == "reality":
        reality = stream.get("realitySettings") or {}
        tls = {"enabled": True}
        copy_if_present(reality, "serverName", tls, "server_name")
        fingerprint = reality.get("fingerprint")
        if fingerprint:
            tls["utls"] = {"enabled": True, "fingerprint": fingerprint}
        reality_target = {"enabled": True}
        copy_if_present(reality, "publicKey", reality_target, "public_key")
        copy_if_present(reality, "shortId", reality_target, "short_id")
        tls["reality"] = reality_target
        target["tls"] = tls
        return

    fail(f"unsupported Xray stream security {security!r}")


def convert_vless(outbound: dict[str, Any], target_tag: str, detour: str | None) -> dict[str, Any]:
    vnext = first_item((outbound.get("settings") or {}).get("vnext"), "vless settings.vnext")
    user = first_item(vnext.get("users"), "vless user list")
    target: dict[str, Any] = {
        "type": "vless",
        "tag": target_tag,
        "server": vnext.get("address"),
        "server_port": vnext.get("port"),
        "uuid": user.get("id"),
    }
    copy_if_present(user, "flow", target, "flow")
    if detour:
        target["detour"] = detour
    stream = outbound.get("streamSettings") or {}
    convert_tls(stream, target)
    convert_transport(stream, target)
    return target


def convert_shadowsocks(outbound: dict[str, Any], target_tag: str, detour: str | None) -> dict[str, Any]:
    server = first_item((outbound.get("settings") or {}).get("servers"), "shadowsocks settings.servers")
    target: dict[str, Any] = {
        "type": "shadowsocks",
        "tag": target_tag,
        "server": server.get("address"),
        "server_port": server.get("port"),
        "method": server.get("method"),
        "password": server.get("password"),
    }
    if detour:
        target["detour"] = detour
    return target


def convert_socks_or_http(outbound: dict[str, Any], target_tag: str, protocol: str, detour: str | None) -> dict[str, Any]:
    server = first_item((outbound.get("settings") or {}).get("servers"), f"{protocol} settings.servers")
    target: dict[str, Any] = {
        "type": "socks" if protocol == "socks" else "http",
        "tag": target_tag,
        "server": server.get("address"),
        "server_port": server.get("port"),
    }
    users = server.get("users") or []
    if users:
        user = first_item(users, f"{protocol} settings.servers.users")
        copy_if_present(user, "user", target, "username")
        copy_if_present(user, "pass", target, "password")
    if detour:
        target["detour"] = detour
    return target


def convert_outbound(outbound: dict[str, Any], target_tag: str, detour: str | None) -> dict[str, Any]:
    protocol = outbound.get("protocol")
    if protocol == "freedom":
        target = {"type": "direct", "tag": target_tag}
        if detour:
            target["detour"] = detour
        return target
    if protocol == "vless":
        return convert_vless(outbound, target_tag, detour)
    if protocol == "shadowsocks":
        return convert_shadowsocks(outbound, target_tag, detour)
    if protocol in {"socks", "http"}:
        return convert_socks_or_http(outbound, target_tag, protocol, detour)
    fail(f"unsupported Xray outbound protocol {protocol!r}")


def require_complete(outbound: dict[str, Any]) -> None:
    required_by_type = {
        "direct": ["tag"],
        "http": ["tag", "server", "server_port"],
        "shadowsocks": ["tag", "server", "server_port", "method", "password"],
        "socks": ["tag", "server", "server_port"],
        "vless": ["tag", "server", "server_port", "uuid"],
    }
    missing = [key for key in required_by_type.get(outbound.get("type"), []) if outbound.get(key) in (None, "")]
    if missing:
        fail(f"converted outbound {outbound.get('tag')} is missing fields: {', '.join(missing)}")


def build_sing_box_outbounds(config: dict[str, Any], inbound_port: int, inbound_tag: str | None) -> tuple[list[dict[str, Any]], str, list[str]]:
    resolved_inbound_tag = find_inbound_tag(config, inbound_port, inbound_tag)
    selected_tag = find_routed_outbound_tag(config, resolved_inbound_tag)
    by_tag = outbounds_by_tag(config)
    chain = resolve_chain(selected_tag, by_tag)

    converted: list[dict[str, Any]] = []
    emitted: set[str] = set()

    # Emit upstream chain first. The selected outbound itself is emitted twice as
    # foreign_clean and domestic so both policy tags use the same clean chain.
    for tag in reversed(chain[1:]):
        outbound = by_tag[tag]
        detour = (outbound.get("proxySettings") or {}).get("tag")
        converted_outbound = convert_outbound(outbound, tag, detour)
        require_complete(converted_outbound)
        converted.append(converted_outbound)
        emitted.add(tag)

    selected = by_tag[selected_tag]
    selected_detour = (selected.get("proxySettings") or {}).get("tag")
    foreign_clean = convert_outbound(selected, "foreign_clean", selected_detour)
    domestic = copy.deepcopy(foreign_clean)
    domestic["tag"] = "domestic"
    for outbound in (foreign_clean, domestic):
        require_complete(outbound)
        converted.append(outbound)
        emitted.add(outbound["tag"])

    return converted, resolved_inbound_tag, chain


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert a local Xray outbound chain into sing-box outbounds")
    parser.add_argument("--source", default="/opt/homebrew/etc/xray/config.json", type=Path)
    parser.add_argument("--inbound-port", default=10811, type=int)
    parser.add_argument("--inbound-tag")
    parser.add_argument("--output", default="config/secrets/sing-box-outbounds.local.json", type=Path)
    args = parser.parse_args()

    config = load_json(args.source)
    outbounds, inbound_tag, chain = build_sing_box_outbounds(config, args.inbound_port, args.inbound_tag)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"outbounds": outbounds}, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    args.output.chmod(0o600)
    protocols = [outbound["type"] for outbound in outbounds]
    print(f"imported inbound={inbound_tag} chain={'->'.join(chain)} outbounds={','.join(protocols)} output={args.output}")


if __name__ == "__main__":
    main()
