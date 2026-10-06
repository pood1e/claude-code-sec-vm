"""Prepare the Apple Silicon host, verified guest assets, and proxy service."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import plistlib
import shutil
import socket
import subprocess
import tarfile
import time
from pathlib import Path

from macos_qemu import CACHE, PROXY_PORT, ROOT, RUN
from render import config as load_config

ISO = RUN / "iso"
SEED = RUN / "seed"
LABEL = "io.github.pood1e.claude-sandbox-proxy"
PLIST = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"
VERSION = "1.14.2"
CLOUD_IMAGE = "ubuntu-26.04-server-cloudimg-arm64.img"
CLOUD_URL = f"https://cloud-images.ubuntu.com/releases/resolute/release-20260927/{CLOUD_IMAGE}"
CLOUD_SHA256 = "63a93bd5a8d76e33b15ceb5daa3657bd79be804748051ab178e643b0f5da22e7"
SING_ARCHIVE = f"sing-box-{VERSION}-linux-arm64.tar.gz"
SING_URL = f"https://github.com/SagerNet/sing-box/releases/download/v{VERSION}/{SING_ARCHIVE}"
SING_SHA256 = "b43a1fb1bda131c6653576741ce527eb2bdeab7c9308ca90ee8b972abb7e4a7f"


def run(*args: object, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(arg) for arg in args],
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
    )


def ensure_config() -> dict:
    RUN.mkdir(mode=0o700, exist_ok=True)
    CACHE.mkdir(exist_ok=True)
    local = ROOT / "config.local.json"
    if not local.exists():
        shutil.copyfile(ROOT / "config.example.json", local)
        print("created config.local.json")
    return load_config()


def firmware() -> tuple[Path, Path]:
    prefix = Path(run("brew", "--prefix", "qemu", capture=True).stdout.strip())
    code = prefix / "share" / "qemu" / "edk2-aarch64-code.fd"
    variables = prefix / "share" / "qemu" / "edk2-aarch64-vars.fd"
    if not code.is_file() or not variables.is_file():
        raise RuntimeError("QEMU ARM UEFI firmware is missing")
    return code, variables


def doctor() -> dict:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("macOS backend requires native Apple Silicon Python")
    for command in (
        "brew",
        "qemu-system-aarch64",
        "qemu-img",
        "xorriso",
        "sing-box",
        "curl",
        "ssh",
        "ssh-keygen",
        "launchctl",
        "nc",
    ):
        if shutil.which(command) is None:
            raise RuntimeError(f"missing command: {command}")
    if "hvf" not in run("qemu-system-aarch64", "-accel", "help", capture=True).stdout:
        raise RuntimeError("QEMU HVF accelerator is unavailable")
    firmware()
    cfg = ensure_config()
    trace = run(
        "curl",
        "-fsS",
        "--max-time",
        "15",
        "--proxy",
        f"socks5h://127.0.0.1:{cfg['upstream_socks_port']}",
        "https://ipinfo.io/json",
        capture=True,
    )
    exit_info = json.loads(trace.stdout)
    if exit_info.get("timezone") != cfg["timezone"]:
        raise RuntimeError(
            f"proxy exit timezone is {exit_info.get('timezone')}, config says {cfg['timezone']}"
        )
    print(
        f"doctor OK: QEMU/HVF available; SOCKS exits via {exit_info.get('country')}/{cfg['timezone']}"
    )
    return cfg


def ensure_key() -> None:
    key = RUN / "id_ed25519"
    if not key.exists():
        run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "claude-sandbox", "-f", key)
        key.chmod(0o600)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, path: Path, expected: str) -> None:
    if path.exists() and sha256(path) == expected:
        return
    print(f"downloading {path.name}")
    run("curl", "-fL", "--retry", "3", "--continue-at", "-", url, "-o", path)
    if sha256(path) != expected:
        raise RuntimeError(f"checksum mismatch: {path.name}")


def assets() -> None:
    download(CLOUD_URL, CACHE / CLOUD_IMAGE, CLOUD_SHA256)
    archive = CACHE / SING_ARCHIVE
    download(SING_URL, archive, SING_SHA256)
    with tarfile.open(archive) as source, (ISO / "sing-box").open("wb") as destination:
        member = source.extractfile(f"sing-box-{VERSION}-linux-arm64/sing-box")
        if member is None:
            raise RuntimeError("sing-box archive has no executable")
        with member:
            shutil.copyfileobj(member, destination)
    (ISO / "sing-box").chmod(0o755)
    run("sing-box", "check", "-c", RUN / "host.json")
    run("sing-box", "check", "-c", ISO / "guest.json")
    run("xorriso", "-as", "mkisofs", "-quiet", "-V", "CLAUDETOOLS", "-o", CACHE / "tools.iso", ISO)
    run("xorriso", "-as", "mkisofs", "-quiet", "-V", "cidata", "-o", CACHE / "seed.iso", SEED)


def proxy_running() -> bool:
    target = f"gui/{os.getuid()}/{LABEL}"
    return (
        subprocess.run(
            ["launchctl", "print", target],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode
        == 0
    )


def start_proxy() -> None:
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    with PLIST.open("wb") as target:
        plistlib.dump(
            {
                "Label": LABEL,
                "ProgramArguments": [shutil.which("sing-box"), "run", "-c", str(RUN / "host.json")],
                "RunAtLoad": True,
                "KeepAlive": True,
                "StandardErrorPath": str(RUN / "proxy.log"),
            },
            target,
        )
    domain = f"gui/{os.getuid()}"
    if proxy_running():
        run("launchctl", "bootout", f"{domain}/{LABEL}")
    run("launchctl", "bootstrap", domain, PLIST)
    for _ in range(20):
        try:
            with socket.create_connection(("127.0.0.1", PROXY_PORT), timeout=0.5):
                return
        except OSError:
            time.sleep(0.5)
    raise RuntimeError(f"host proxy failed; inspect {RUN / 'proxy.log'}")
