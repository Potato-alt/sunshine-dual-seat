#!/bin/bash
# sunshine-dual-seat installer (server side).
# Fills @VARS@ in the repo files and copies them into place.
# Reviewed-for-humans version: every block matches docs/runbook.md — read it first.
#
# Tested on CachyOS/Arch, Oct 2026. Run as root:  sudo ./install.sh
set -euo pipefail

######################### EDIT THESE #########################################
DESKTOP_USER=arm            # existing local desktop user (Plasma/X11)
OPERATOR_USER=operator      # dedicated user for the remote streamed session
OPERATOR_UID=1001           # fixed uid; /run/user/<uid> paths depend on it
SEAT_TTY=tty2               # a VT free of the local display manager
SERVER_IP=10.10.0.103       # LAN IP of this machine (Sunshine web UI origin)
RENDER_NODE=/dev/dri/renderD129   # iGPU render node for VAAPI encoding (Step 0 of runbook)
SSH_KEY=~/.ssh/id_ed25519_lan     # client-side key for the clipboard bridge
INSTALL_NVIDIA_PIN=yes      # pin local X to NVIDIA (no if no discrete GPU)
###############################################################################

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OPERATOR_HOME="/home/$OPERATOR_USER"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fill() {  # fill <src> <dst>
  sed -e "s|@DESKTOP_USER@|$DESKTOP_USER|g" \
      -e "s|@OPERATOR_USER@|$OPERATOR_USER|g" \
      -e "s|@OPERATOR_UID@|$OPERATOR_UID|g" \
      -e "s|@OPERATOR_HOME@|$OPERATOR_HOME|g" \
      -e "s|@SEAT_TTY@|$SEAT_TTY|g" \
      -e "s|@SERVER_IP@|$SERVER_IP|g" \
      -e "s|@RENDER_NODE@|$RENDER_NODE|g" \
      -e "s|@SSH_KEY@|$SSH_KEY|g" \
      "$REPO_DIR/$1" > "$TMP/$(basename "$1")" && echo "$TMP/$(basename "$1")"
}

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

echo "== [1/8] remote user =="
id "$OPERATOR_USER" >/dev/null 2>&1 || \
  useradd -m -u "$OPERATOR_UID" -G input,video,render "$OPERATOR_USER"
loginctl enable-linger "$OPERATOR_USER"
passwd -l "$OPERATOR_USER" >/dev/null 2>&1 || true

echo "== [2/8] directories =="
install -d -o "$OPERATOR_USER" -g "$OPERATOR_USER" \
  "$OPERATOR_HOME/.config/sway-sunshine" \
  "$OPERATOR_HOME/.config/sunshine/icons" \
  "$OPERATOR_HOME/.config/pipewire/pipewire.conf.d"

echo "== [3/8] systemd units =="
install -m 644 "$(fill server/units/sway-sunshine.service)"   /etc/systemd/system/
install -m 644 "$(fill server/units/sunshine-stream.service)" /etc/systemd/system/
systemctl daemon-reload

echo "== [4/8] session scripts (as $OPERATOR_USER) =="
for f in run-sunshine.sh set-resolution.sh reset-resolution.sh ticker.sh \
         server-control.sh server-control-launch.sh tile-factorio.sh tile-sts2.sh; do
  install -m 755 -o "$OPERATOR_USER" -g "$OPERATOR_USER" \
    "$(fill server/scripts/$f)" "$OPERATOR_HOME/.config/sway-sunshine/$f"
done
install -m 644 -o "$OPERATOR_USER" -g "$OPERATOR_USER" \
  "$(fill server/configs/sway-sunshine.config)" "$OPERATOR_HOME/.config/sway-sunshine/config"

echo "== [5/8] sunshine config =="
install -m 644 -o "$OPERATOR_USER" -g "$OPERATOR_USER" \
  "$(fill server/configs/sunshine.conf)" "$OPERATOR_HOME/.config/sunshine/sunshine.conf"
install -m 644 -o "$OPERATOR_USER" -g "$OPERATOR_USER" \
  "$(fill server/configs/apps.json)" "$OPERATOR_HOME/.config/sunshine/apps.json"
install -m 644 -o "$OPERATOR_USER" -g "$OPERATOR_USER" \
  server/configs/pipewire/sunshine-null-sink.conf \
  "$OPERATOR_HOME/.config/pipewire/pipewire.conf.d/sunshine-null-sink.conf"

echo "== [6/8] root helpers + xorg + sudoers =="
install -m 755 "$(fill server/scripts/stream-restart)"        /usr/local/bin/
install -m 755 "$(fill server/scripts/game-clip-in)"          /usr/local/bin/
install -m 755 "$(fill server/scripts/game-clip-out)"         /usr/local/bin/
install -m 755 "$(fill server/scripts/sunshine-isolate-inputs)" /usr/local/bin/
install -d /etc/X11/xorg.conf.d
install -m 644 "$(fill server/xorg/50-ignore-sunshine-input.conf)" /etc/X11/xorg.conf.d/
if [ "$INSTALL_NVIDIA_PIN" = yes ]; then
  install -m 644 "$(fill server/xorg/10-nvidia-primary.conf)" /etc/X11/xorg.conf.d/
fi
for s in game-admin arm-clipboard; do
  T="$(fill server/sudoers/$s)"
  visudo -cf "$T" >/dev/null   # never install a broken sudoers file
  install -m 440 "$T" "/etc/sudoers.d/$s"
done

echo "== [7/8] start the stack =="
systemctl enable --now sway-sunshine.service
sleep 10
systemctl enable --now sunshine-stream.service || true

echo "== [8/8] manual leftovers (NOT done automatically) =="
cat <<EOF
1. Pin versions in /etc/pacman.conf:
     IgnorePkg = sunshine sway wlroots0.17
2. Run the input isolation as the DESKTOP user (their session must be running):
     sudo -u $DESKTOP_USER env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u $DESKTOP_USER)/bus \
       /usr/local/bin/sunshine-isolate-inputs
   (repeat after connecting with a gamepad)
3. Pair Moonlight: https://$SERVER_IP:47990  (enter the PIN within seconds)
4. Verify:  ./verify.sh   and a real test stream (docs/runbook.md step 9).
EOF
echo "install done."
