#!/bin/sh
SWAYSOCK=/run/user/@OPERATOR_UID@/sway-sunshine.sock XDG_RUNTIME_DIR=/run/user/@OPERATOR_UID@ \
  swaymsg "output HEADLESS-1 mode 1920x1080@60Hz" >/dev/null 2>&1
exit 0
