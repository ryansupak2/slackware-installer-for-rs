#!/bin/sh

# Source temp-msg helper
if [ -f /usr/local/bin/temp-msg.sh ]; then . /usr/local/bin/temp-msg.sh
else set_temp_msg() { echo "$1" > "$XDG_RUNTIME_DIR/status_msg"; echo $(($(date +%s) + ${2:-4})) > "$XDG_RUNTIME_DIR/status_end"; }; fi
device=$(ls /sys/class/backlight/ | head -1)
if [ -n "$device" ]; then
    max=$(cat /sys/class/backlight/$device/max_brightness)
    current=$(cat /sys/class/backlight/$device/brightness)
    new=$((current - max / 20))
    if [ $new -lt 0 ]; then new=0; fi
    echo $new > /sys/class/backlight/$device/brightness
    percent=$((new * 100 / max))
    set_temp_msg "Brightness: $percent%"
fi