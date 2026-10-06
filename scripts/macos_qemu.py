"""QEMU process and monitor operations for the Apple Silicon backend."""

from __future__ import annotations

import json
import os
import socket
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUN = ROOT / "runtime"
CACHE = RUN / "cache"
DISK = RUN / "claude-sandbox.qcow2"
SSH_PORT = 10022
PROXY_PORT = 10980


def running() -> bool:
    try:
        pid = int((RUN / "qemu.pid").read_text())
        os.kill(pid, 0)
    except (ValueError, FileNotFoundError, ProcessLookupError):
        return False
    try:
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(1)
            connection.connect(str(RUN / "qmp.sock"))
            return bool(connection.recv(1))
    except OSError as exc:
        raise RuntimeError(f"QEMU PID {pid} exists but QMP is unavailable") from exc


def command(cfg: dict, code: Path) -> list[str]:
    return [
        "qemu-system-aarch64",
        "-name",
        "claude-sandbox",
        "-M",
        "virt,accel=hvf",
        "-cpu",
        "host",
        "-nodefaults",
        "-smp",
        str(cfg["vcpus"]),
        "-m",
        str(cfg["memory_mib"]),
        "-display",
        "none",
        "-serial",
        f"file:{RUN / 'console.log'}",
        "-monitor",
        "none",
        "-qmp",
        f"unix:{RUN / 'qmp.sock'},server=on,wait=off",
        "-daemonize",
        "-pidfile",
        str(RUN / "qemu.pid"),
        "-drive",
        f"if=pflash,format=raw,readonly=on,file={code}",
        "-drive",
        f"if=pflash,format=raw,file={RUN / 'uefi-vars.fd'}",
        "-drive",
        f"if=none,id=disk,format=qcow2,file={DISK}",
        "-device",
        "virtio-blk-pci,drive=disk",
        "-drive",
        f"if=none,id=tools,format=raw,readonly=on,file={CACHE / 'tools.iso'}",
        "-device",
        "virtio-blk-pci,drive=tools",
        "-drive",
        f"if=none,id=seed,format=raw,readonly=on,file={CACHE / 'seed.iso'}",
        "-device",
        "virtio-blk-pci,drive=seed",
        "-netdev",
        (
            "user,id=net0,restrict=on,ipv6=off,"
            f"hostfwd=tcp:127.0.0.1:{SSH_PORT}-10.0.2.15:22,"
            f"guestfwd=tcp:10.0.2.100:{PROXY_PORT}-cmd:nc 127.0.0.1 {PROXY_PORT}"
        ),
        "-device",
        "virtio-net-pci,netdev=net0,mac=52:54:00:71:00:02",
    ]


def qmp(command_name: str) -> None:
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(str(RUN / "qmp.sock"))
        with connection.makefile("rwb") as channel:
            channel.readline()
            for request in ("qmp_capabilities", command_name):
                channel.write(json.dumps({"execute": request}).encode() + b"\n")
                channel.flush()
                while True:
                    response = json.loads(channel.readline())
                    if "error" in response:
                        raise RuntimeError(str(response["error"]))
                    if "return" in response:
                        break


def stop() -> None:
    if not running():
        print("VM already stopped")
        return
    qmp("system_powerdown")
    for _ in range(60):
        if not running():
            print("VM stopped")
            return
        time.sleep(1)
    raise RuntimeError("VM did not shut down; inspect the guest before retrying")
