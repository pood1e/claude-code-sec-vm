"""Run the isolated Claude VM on Apple Silicon with QEMU/HVF."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys

from macos_host import (
    CLOUD_IMAGE,
    ISO,
    assets,
    doctor,
    ensure_config,
    ensure_key,
    firmware,
    proxy_running,
    run,
    start_proxy,
)
from macos_qemu import (
    CACHE,
    DISK,
    ROOT,
    RUN,
    SSH_PORT,
    stop,
)
from macos_qemu import (
    command as qemu_command,
)
from macos_qemu import (
    running as vm_running,
)


def config_hash(cfg: dict) -> str:
    return hashlib.sha256(json.dumps(cfg, sort_keys=True).encode()).hexdigest()


def up() -> None:
    cfg = doctor()
    ensure_key()
    run(sys.executable, ROOT / "scripts" / "render.py", "--platform", "macos")
    marker = RUN / "config.sha256"
    if DISK.exists() and (not marker.exists() or marker.read_text().strip() != config_hash(cfg)):
        raise RuntimeError("VM config changed; run ./claude-vm rebuild --yes to apply it")
    guest_hash = hashlib.sha256(
        b"".join(
            (ISO / name).read_bytes() for name in ("guest.json", "bootstrap.sh", "guest.service")
        )
    ).hexdigest()
    guest_marker = RUN / "guest.sha256"
    if DISK.exists() and (
        not guest_marker.exists() or guest_marker.read_text().strip() != guest_hash
    ):
        raise RuntimeError("guest policy changed; run ./claude-vm rebuild --yes to apply it")
    run("sing-box", "check", "-c", RUN / "host.json")
    if vm_running():
        start_proxy()
        print("VM already running")
        return
    assets()
    start_proxy()
    code, variables = firmware()
    if not DISK.exists():
        run(
            "qemu-img",
            "create",
            "-f",
            "qcow2",
            "-F",
            "qcow2",
            "-b",
            CACHE / CLOUD_IMAGE,
            DISK,
            f"{cfg['disk_gib']}G",
        )
        shutil.copyfile(variables, RUN / "uefi-vars.fd")
        marker.write_text(config_hash(cfg) + "\n")
        guest_marker.write_text(guest_hash + "\n")
        known_hosts = RUN / "known_hosts"
        if known_hosts.exists():
            run("ssh-keygen", "-f", known_hosts, "-R", f"[127.0.0.1]:{SSH_PORT}")
    (RUN / "qmp.sock").unlink(missing_ok=True)
    (RUN / "qemu.pid").unlink(missing_ok=True)
    run(*qemu_command(cfg, code))
    print("VM started. Bootstrap runs inside the guest; check with: ./claude-vm status")


def ssh_command(*command: str) -> list[object]:
    if not (RUN / "id_ed25519").exists():
        raise RuntimeError("run ./claude-vm up first")
    return [
        "ssh",
        "-F",
        "/dev/null",
        "-i",
        RUN / "id_ed25519",
        "-p",
        SSH_PORT,
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "IdentityAgent=none",
        "-o",
        "ForwardAgent=no",
        "-o",
        "ForwardX11=no",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        f"UserKnownHostsFile={RUN / 'known_hosts'}",
        "-o",
        "ConnectTimeout=8",
        "agent@127.0.0.1",
        *command,
    ]


def ssh_guest(*command: str, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return run(*ssh_command(*command), capture=capture)


def status() -> None:
    print(f"VM: {'running' if vm_running() else 'stopped'}")
    print(f"host proxy: {'loaded' if proxy_running() else 'stopped'}")
    if vm_running():
        result = subprocess.run(
            [str(arg) for arg in ssh_command("test -f /var/lib/claude-sandbox-ready")],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        print(f"guest bootstrap: {'ready' if result.returncode == 0 else 'pending'}")


def check() -> None:
    ssh_guest("test -f /var/lib/claude-sandbox-ready")
    ssh_guest(
        'test "$(id -un)" = agent && ! id -nG | grep -qw sudo && '
        "systemctl is-active --quiet claude-sandbox-net.service && "
        'test "$(jq -r .env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC ~/.claude/settings.json)" = 1 && '
        '! env | grep -Ei "^(http_proxy|https_proxy|all_proxy|TZ)="'
    )
    cfg = ensure_config()
    timezone = ssh_guest("timedatectl show -p Timezone --value", capture=True).stdout.strip()
    if timezone != cfg["timezone"]:
        raise RuntimeError(f"guest timezone is {timezone}, config says {cfg['timezone']}")
    trace = json.loads(
        ssh_guest("curl -fsS --max-time 20 https://ipinfo.io/json", capture=True).stdout
    )
    if trace.get("timezone") != timezone:
        raise RuntimeError(
            f"guest exit timezone is {trace.get('timezone')}, config says {timezone}"
        )
    metadata = subprocess.run(
        [str(arg) for arg in ssh_command('timeout 4 bash -c "</dev/tcp/169.254.169.254/80"')],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if metadata.returncode == 0:
        raise RuntimeError("metadata endpoint reachable")
    ssh_guest('timeout 4 bash -c "</dev/tcp/10.0.2.100/10980"')
    print(f"check OK: isolated guest, timezone {timezone}, proxied egress {trace.get('country')}")


def main() -> None:
    if len(sys.argv) < 2:
        raise RuntimeError(
            "usage: ./claude-vm {doctor|up|start|stop|status|check|ssh|rebuild --yes}"
        )
    command = sys.argv[1]
    if command == "doctor":
        doctor()
    elif command in ("up", "start"):
        up()
    elif command == "stop":
        stop()
    elif command == "status":
        status()
    elif command == "check":
        check()
    elif command == "ssh":
        ssh_guest(*sys.argv[2:])
    elif command == "rebuild" and sys.argv[2:] == ["--yes"]:
        stop()
        DISK.unlink(missing_ok=True)
        (RUN / "uefi-vars.fd").unlink(missing_ok=True)
        (RUN / "config.sha256").unlink(missing_ok=True)
        (RUN / "guest.sha256").unlink(missing_ok=True)
        up()
    else:
        raise RuntimeError(
            "usage: ./claude-vm {doctor|up|start|stop|status|check|ssh|rebuild --yes}"
        )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        sys.exit(f"error: {exc}")
