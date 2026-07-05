#!/bin/sh
device="/sys/class/leds/tpacpi::kbd_backlight"
if [ -d "$device" ]; then
    max=$(cat $device/max_brightness)
    current=$(cat $device/brightness)
    new=$((current + 1))
    if [ $new -gt $max ]; then new=$max; fi
    echo $new > $device/brightness
    percent=$((new * 100 / max))
    echo "Keyboard Brightness: $percent%" > /tmp/status_msg
    echo $(($(date +%s) + 3)) > /tmp/status_end
fi