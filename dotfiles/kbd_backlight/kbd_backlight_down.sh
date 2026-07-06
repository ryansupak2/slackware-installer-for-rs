#!/bin/sh

# Source temp-msg helper
if [ -f /usr/local/bin/temp-msg.sh ]; then . /usr/local/bin/temp-msg.sh
else set_temp_msg() { echo "$1" > "$XDG_RUNTIME_DIR/status_msg"; echo $(($(date +%s) + ${2:-4})) > "$XDG_RUNTIME_DIR/status_end"; }; fi
device="/sys/class/leds/tpacpi::kbd_backlight"
if [ -d "$device" ]; then
    max=$(cat $device/max_brightness)
    current=$(cat $device/brightness)
    new=$((current - 1))
    if [ $new -lt 0 ]; then new=0; fi
    echo $new > $device/brightness
    percent=$((new * 100 / max))
    set_temp_msg "Keyboard Brightness: $percent%"
fi