#!/bin/bash
# Launcher for the Server Control tile: opens kitty inside the remote session.
# NOTE: DISPLAY/WAYLAND_DISPLAY are pinned to the values this setup reliably
# produces (Xwayland :1, sway socket wayland-1). If your numbering differs,
# check `ls /tmp/.X11-unix` and `ls /run/user/<uid>/wayland-*`.
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/@OPERATOR_UID@/bus
export DISPLAY=:1 WAYLAND_DISPLAY=wayland-1
export XDG_RUNTIME_DIR=/run/user/@OPERATOR_UID@ HOME=@OPERATOR_HOME@
exec kitty --class server-control -e @OPERATOR_HOME@/.config/sway-sunshine/server-control.sh
