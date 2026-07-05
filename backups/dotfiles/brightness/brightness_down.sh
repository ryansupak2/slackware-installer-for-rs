#!/bin/sh
device=$(ls /sys/class/backlight/ | head -1)
if [ -n "$device" ]; then
    max=$(cat /sys/class/backlight/$device/max_brightness)
    current=$(cat /sys/class/backlight/$device/brightness)
    new=$((current - max / 10))
    if [ $new -lt 0 ]; then new=0; fi
    echo $new > /sys/class/backlight/$device/brightness
    percent=$((new * 100 / max))
    echo "Brightness: $percent%" > /tmp/status_msg
    echo $(($(date +%s) + 3)) > /tmp/status_end
fi