#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

VNC_PASSWORD_FILE=${VNC_PASSWORD_FILE:-$ROOT_DIR/runtime/vnc-password.txt}
VNC_GEOMETRY=${VNC_GEOMETRY:-1440x900}

ensure_vnc_password_file() {
  if [[ -s "$VNC_PASSWORD_FILE" ]]; then
    chmod 600 "$VNC_PASSWORD_FILE"
    return
  fi

  mkdir -p "$(dirname "$VNC_PASSWORD_FILE")"
  python3 - <<'PY' >"$VNC_PASSWORD_FILE.tmp"
import secrets

alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
print("".join(secrets.choice(alphabet) for _ in range(8)))
PY
  chmod 600 "$VNC_PASSWORD_FILE.tmp"
  mv "$VNC_PASSWORD_FILE.tmp" "$VNC_PASSWORD_FILE"
}

ensure_vnc_password_file

remote_prepare=$(cat <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y tigervnc-standalone-server tigervnc-common dbus-x11 kali-desktop-xfce

mkdir -p ~/.vnc
chmod 700 ~/.vnc
cat >~/.vnc/xstartup <<'XSTARTUP'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
[ -r "$HOME/.Xresources" ] && xrdb "$HOME/.Xresources"
xset s off s noblank -dpms 2>/dev/null || true
xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s false 2>/dev/null || true
exec dbus-launch --exit-with-session startxfce4
XSTARTUP
chmod 755 ~/.vnc/xstartup
mkdir -p ~/.config/autostart
cat >~/.config/autostart/xfce4-screensaver.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=xfce4-screensaver
Exec=xfce4-screensaver
Hidden=true
DESKTOP

sudo tee /etc/systemd/system/ccsvm-vnc-dev.service >/dev/null <<UNIT
[Unit]
Description=claude-code-sec-vm TigerVNC desktop for dev
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=dev
Group=dev
Environment=HOME=/home/dev
ExecStartPre=/bin/sh -c '/usr/bin/tigervncserver -kill :1 >/dev/null 2>&1 || true'
ExecStart=/usr/bin/tigervncserver :1 -fg -geometry ${VNC_GEOMETRY} -depth 24 -localhost no -SecurityTypes VncAuth -AcceptSetDesktopSize=0 -CompareFB=2 -UseBlacklist=0
ExecStop=/usr/bin/tigervncserver -kill :1
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
REMOTE
)

ssh \
  "${SSH_VM_OPTS[@]}" \
  "dev@$DEV_IP" \
  "VNC_GEOMETRY=$(shell_quote "$VNC_GEOMETRY") bash -s" <<<"$remote_prepare"

ssh \
  "${SSH_VM_OPTS[@]}" \
  "dev@$DEV_IP" \
  'umask 077; mkdir -p ~/.vnc; vncpasswd -f >~/.vnc/passwd; chmod 600 ~/.vnc/passwd' <"$VNC_PASSWORD_FILE"

remote_start=$(cat <<'REMOTE'
set -euo pipefail
sudo systemctl enable ccsvm-vnc-dev >/dev/null
sudo systemctl restart ccsvm-vnc-dev
systemctl is-active --quiet ccsvm-vnc-dev
for attempt in $(seq 1 60); do
  if timeout 2 bash -c '</dev/tcp/127.0.0.1/5901' >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" -eq 60 ]; then
    systemctl status ccsvm-vnc-dev --no-pager -n 40 || true
    exit 1
  fi
  sleep 1
done
DISPLAY=:1 xset s off s noblank -dpms >/dev/null 2>&1 || true
DISPLAY=:1 xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s false >/dev/null 2>&1 || true
printf 'vnc=enabled display=:1 guest_port=5901 password_file=%s\n' "$VNC_PASSWORD_FILE"
REMOTE
)

ssh \
  "${SSH_VM_OPTS[@]}" \
  "dev@$DEV_IP" \
  "VNC_PASSWORD_FILE=$(shell_quote "$VNC_PASSWORD_FILE") bash -s" <<<"$remote_start"
