#!/bin/bash
# Waits for a fully ready compositor + Xwayland display, then execs sunshine.
# Readiness = wayland socket LOCKED by live sway (flock is released on SIGKILL,
# so stale sockets are rejected) AND sway IPC reporting HEADLESS-1.
# Sockets/devices matched by uid, not username (rename-proof).
OP_UID=@OPERATOR_UID@
export SWAYSOCK="/run/user/$OP_UID/sway-sunshine.sock"

wl_live() {
  local s="$1"
  [ -S "$s" ] || return 1
  [ -e "$s.lock" ] || return 1
  if flock -n "$s.lock" true 2>/dev/null; then
    return 1   # lock free -> stale socket from a SIGKILLed sway
  fi
  return 0
}
outputs_ready() {
  swaymsg -s "$SWAYSOCK" -t get_outputs 2>/dev/null | grep -q "HEADLESS-1"
}

READY=""
for i in $(seq 1 60); do
  for s in /run/user/$OP_UID/wayland-*; do
    case "$s" in *.lock) continue;; esac
    if wl_live "$s"; then
      export WAYLAND_DISPLAY="${s##*/}"
      if outputs_ready; then READY=1; break 2; fi
    fi
  done
  sleep 0.5
done
[ -z "$READY" ] && { echo "run-sunshine: no READY wayland compositor in 30s" >&2; exit 1; }

for k in $(seq 1 20); do
  for xf in /tmp/.X11-unix/X*; do
    [ -S "$xf" ] || continue
    [ "$(stat -c %u "$xf" 2>/dev/null)" = "$OP_UID" ] || continue
    export DISPLAY=":${xf##*X}"
    break 2
  done
  sleep 0.5
done
[ -z "${DISPLAY:-}" ] && echo "run-sunshine: no operator-owned X socket in 10s, starting without DISPLAY" >&2
exec /usr/bin/sunshine
