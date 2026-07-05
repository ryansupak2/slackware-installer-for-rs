#!/bin/sh
# Fn+F2 - Volume Down via PipeWire pulse interface

pactl set-sink-volume @DEFAULT_SINK@ -5% 2>/dev/null

vol=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | head -1 | grep -oP '\d+%' | head -1)
[ -z "$vol" ] && vol="??%"
echo "Volume: ${vol}" > /tmp/status_msg
echo $(($(date +%s) + 3)) > /tmp/status_end
