#!/bin/sh
# Fn+F1 - Mute/Unmute toggle via PipeWire pulse interface

pactl set-sink-mute @DEFAULT_SINK@ toggle 2>/dev/null

muted=$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | grep -oP 'yes|no')
vol=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | head -1 | grep -oP '\d+%' | head -1)
[ -z "$vol" ] && vol="??%"

if [ "$muted" = "yes" ]; then
    echo "Volume: ${vol} (muted)" > /tmp/status_msg
else
    echo "Volume: ${vol}" > /tmp/status_msg
fi
echo $(($(date +%s) + 3)) > /tmp/status_end
