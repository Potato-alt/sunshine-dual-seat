#!/bin/bash
# Server Control — in-stream management menu (a Moonlight tile opens this
# in a kitty terminal inside the remote session).
export XDG_RUNTIME_DIR=/run/user/@OPERATOR_UID@
export SWAYSOCK=/run/user/@OPERATOR_UID@/sway-sunshine.sock
CONF=@OPERATOR_HOME@/.config/sway-sunshine/config
SINK=sink-sunshine-stereo
# Sunshine passthrough mouse identifiers (uinput vendor:product are fixed)
MOUSE_IDS=("48879:57005:Mouse_passthrough" "48879:57005:Mouse_passthrough_(absolute)")

vol()   { pactl get-sink-volume $SINK 2>/dev/null | grep -o '[0-9]*%' | head -1; }
mouse() { grep -m1 -o 'pointer_accel [0-9.-]*' $CONF 2>/dev/null | cut -d' ' -f2; }

while true; do
  clear
  echo "================================================"
  echo "          SERVER CONTROL  @SERVER_IP@"
  echo "================================================"
  echo "  Volume: $(vol)   Mouse accel: $(mouse)"
  echo "------------------------------------------------"
  echo "   1) Volume: enter percent (100-200)"
  echo "   2) Volume 130%        3) Volume 150%"
  echo "   4) Mute toggle"
  echo "   5) Mouse sensitivity: enter (0.1-1.0)"
  echo "   6) System monitor (btop)"
  echo "   7) GUI mixer (pavucontrol)"
  echo "   8) Sunshine log (tail)"
  echo "   9) Restart stream session (~15 s)"
  echo "  10) Reboot server"
  echo "  11) Power off server"
  echo "   0) Exit"
  echo "------------------------------------------------"
  read -rp "Choice> " c
  case "$c" in
    1) read -rp "Percent (e.g. 140): " v; pactl set-sink-volume $SINK "$v%" ;;
    2) pactl set-sink-volume $SINK 130% ;;
    3) pactl set-sink-volume $SINK 150% ;;
    4) pactl set-sink-mute $SINK toggle ;;
    5) read -rp "Pointer acceleration (0.1-1.0): " m
       for id in "${MOUSE_IDS[@]}"; do
         swaymsg "input \"$id\" pointer_accel $m" >/dev/null 2>&1
       done
       sed -i "s/pointer_accel [0-9.-]*/pointer_accel $m/g" $CONF ;;
    6) btop ;;
    7) pavucontrol ;;
    8) tail -n 40 @OPERATOR_HOME@/.config/sunshine/sunshine.log | less ;;
    9) read -rp "The stream will drop and return in ~15 s. Sure? (y/N): " q
       [ "$q" = "y" ] && sudo -n /usr/local/bin/stream-restart && exit 0 ;;
    10) read -rp "Reboot the server? (y/N): " q; [ "$q" = "y" ] && sudo -n systemctl reboot ;;
    11) read -rp "POWER OFF the server? (y/N): " q; [ "$q" = "y" ] && sudo -n systemctl poweroff ;;
    0) exit 0 ;;
  esac
done
