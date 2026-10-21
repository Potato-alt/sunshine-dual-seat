#!/bin/bash
# sunshine-dual-seat health check. Run ON THE SERVER after install/reboot.
# Fill the four variables (or let install.sh fill them). No changes are made.
DESKTOP_USER=arm
OPERATOR_USER=operator
OPERATOR_UID=1001
SERVER_IP=10.10.0.103

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# 1. units
systemctl is-active --quiet sway-sunshine.service \
  && ok "sway-sunshine active" || bad "sway-sunshine not active"
systemctl is-active --quiet sunshine-stream.service \
  && ok "sunshine-stream active" || bad "sunshine-stream not active"

# 2. wayland socket is live (lock held = living sway)
SOCK=/run/user/$OPERATOR_UID/sway-sunshine.sock
if [ -S "$SOCK" ] && [ -e "$SOCK.lock" ] && ! flock -n "$SOCK.lock" true 2>/dev/null; then
  ok "sway wayland socket live ($SOCK)"
else
  bad "sway wayland socket missing or stale ($SOCK)"
fi

# 3. virtual output present
sudo -u "$OPERATOR_USER" env XDG_RUNTIME_DIR=/run/user/$OPERATOR_UID \
  SWAYSOCK=$SOCK swaymsg -t get_outputs 2>/dev/null | grep -q HEADLESS-1 \
  && ok "HEADLESS-1 output present" || bad "HEADLESS-1 missing"

# 4. ports listening
for p in 47984 47989 47990 48010; do
  ss -tln 2>/dev/null | grep -q ":$p " && ok "port $p listening" || bad "port $p not listening"
done

# 5. sunshine encoder: vaapi, never nvenc
CONF=/home/$OPERATOR_USER/.config/sunshine/sunshine.conf
grep -q '^encoder = vaapi' "$CONF" 2>/dev/null && ok "encoder = vaapi" || bad "encoder != vaapi (NEVER use nvenc, see gotchas 2.2)"
grep -q '^system_tray = disabled' "$CONF" 2>/dev/null && ok "system_tray disabled" || bad "system_tray not disabled (tray deadlock, gotchas 2.1)"

# 6. version pinning
grep -q 'IgnorePkg.*sunshine' /etc/pacman.conf 2>/dev/null \
  && ok "sunshine pinned via IgnorePkg" || bad "sunshine not in IgnorePkg"

# 7. passthrough devices exist (sunshine running = devices created)
grep -q 'passthrough' /proc/bus/input/devices \
  && ok "virtual input devices present" || bad "no passthrough devices (sunshine up?)"

# 8. input isolation: KWin must have them disabled (needs desktop session running)
if pgrep -x kwin_wayland >/dev/null; then
  D=$(sudo -u "$DESKTOP_USER" env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$DESKTOP_USER")/bus \
      busctl --user call org.kde.KWin /org/freedesktop/DBus/ObjectManager \
      org.freedesktop.DBus.ObjectManager GetManagedObjects 2>/dev/null)
  for ev in $(grep -B4 'passthrough' /proc/bus/input/devices | grep -oE 'event[0-9]+' | sort -u); do
    st=$(sudo -u "$DESKTOP_USER" env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$DESKTOP_USER")/bus \
         busctl --user get-property org.kde.KWin "/org/kde/KWin/InputDevice/$ev" \
         org.kde.KWin.InputDevice enabled 2>/dev/null)
    [ "$st" = "b false" ] && ok "KWin has $ev disabled" || bad "KWin has $ev ENABLED — input leaks (run sunshine-isolate-inputs)"
  done
else
  echo "SKIP: local kwin_wayland not running (log in to check isolation)"
fi

# 9. sway side: passthrough enabled, physical disabled
SW_IN=$(sudo -u "$OPERATOR_USER" env XDG_RUNTIME_DIR=/run/user/$OPERATOR_UID \
        SWAYSOCK=$SOCK swaymsg -t get_inputs 2>/dev/null)
echo "$SW_IN" | python3 -c '
import json,sys
try: devs=json.load(sys.stdin)
except Exception: sys.exit(3)
bad=0
for d in devs:
    se=d.get("libinput",{}).get("send_events")
    if "passthrough" in d["identifier"] and se!="enabled": bad=1
    if "passthrough" not in d["identifier"] and se!="disabled": bad=1
sys.exit(bad)' \
  && ok "sway input filters correct" || bad "sway input filters wrong (check sway config)"

# 10. null sink
sudo -u "$OPERATOR_USER" env XDG_RUNTIME_DIR=/run/user/$OPERATOR_UID \
  pactl list short sinks 2>/dev/null | grep -q sink-sunshine-stereo \
  && ok "stream audio sink present" || bad "sink-sunshine-stereo missing"

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ] && echo "HEALTHY" || echo "NOT HEALTHY — see docs/gotchas.md"
exit "$fail"
