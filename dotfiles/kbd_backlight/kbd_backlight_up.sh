#!/bin/sh

# Source temp-msg helper
if [ -f /usr/local/bin/temp-msg.sh ]; then . /usr/local/bin/temp-msg.sh
else set_temp_msg() { echo "$1" > /tmp/status_msg; echo $(($(date +%s) + ${2:-4})) > /tmp/status_end; }; fi
device="/sys/class/leds/tpacpi::kbd_backlight"
if [ -d "$device" ]; then
    max=$(cat $device/max_brightness)
    current=$(cat $device/brightness)
    new=$((current + 1))
    if [ $new -gt $max ]; then new=$max; fi
    echo $new > $device/brightness
    percent=$((new * 100 / max))
    set_temp_msg "Keyboard Brightness: $percent%"
fi