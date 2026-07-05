#!/bin/sh
# Fn+F3 - Volume Up (raise + unmute, max 150%) via PipeWire pulse interface

CUR=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | head -1 | grep -oP '\d+%' | head -1 | tr -d '%')
CUR=${CUR:-0}
if [ "$CUR" -lt 150 ]; then
    pactl set-sink-volume @DEFAULT_SINK@ +5% 2>/dev/null
fi
pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null

vol=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | head -1 | grep -oP '\d+%' | head -1)
[ -z "$vol" ] && vol="??%"
echo "Volume: ${vol}" > /tmp/status_msg
echo $(($(date +%s) + 3)) > /tmp/status_end
