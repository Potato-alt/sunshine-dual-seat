#!/bin/bash
export DISPLAY=:1 WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/@OPERATOR_UID@ HOME=@OPERATOR_HOME@
cd "@OPERATOR_HOME@/Slay the Spire 2/game"
exec ./launch_vulkan.sh
