#!/bin/sh
# Fn+F3 - Volume Up (raise + unmute, max 150%) via PipeWire pulse interface

# Source temp-msg helper
if [ -f /usr/local/bin/temp-msg.sh ]; then . /usr/local/bin/temp-msg.sh
else set_temp_msg() { echo "$1" > /tmp/status_msg; echo $(($(date +%s) + ${2:-4})) > /tmp/status_end; }; fi

CUR=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | head -1 | grep -oP '\d+%' | head -1 | tr -d '%')
CUR=${CUR:-0}
if [ "$CUR" -lt 150 ]; then
    pactl set-sink-volume @DEFAULT_SINK@ +5% 2>/dev/null
fi
pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null

vol=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | head -1 | grep -oP '\d+%' | head -1)
[ -z "$vol" ] && vol="??%"
set_temp_msg "Volume: ${vol}"
