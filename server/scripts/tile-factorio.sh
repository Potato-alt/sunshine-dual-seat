#!/bin/bash
export DISPLAY=:1 WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/@OPERATOR_UID@ HOME=@OPERATOR_HOME@
exec "@OPERATOR_HOME@/.local/share/Steam/steamapps/common/Factorio/bin/x64/factorio"
