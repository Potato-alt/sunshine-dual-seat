#!/bin/sh
# 1-second ticker for swaybar: provides constant damage on the static
# headless output so Sunshine's wlgrab (copy_with_damage) gets frames.
while true; do
  date +%H:%M:%S
  sleep 1
done
