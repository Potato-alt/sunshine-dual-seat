#!/bin/sh
W=${SUNSHINE_CLIENT_WIDTH:-1920}; H=${SUNSHINE_CLIENT_HEIGHT:-1080}; FPS=${SUNSHINE_CLIENT_FPS:-60}
SWAYSOCK=/run/user/@OPERATOR_UID@/sway-sunshine.sock XDG_RUNTIME_DIR=/run/user/@OPERATOR_UID@ \
  swaymsg "output HEADLESS-1 mode ${W}x${H}@${FPS}Hz" >/dev/null 2>&1
exit 0
