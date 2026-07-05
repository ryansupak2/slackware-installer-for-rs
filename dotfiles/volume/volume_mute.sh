#!/bin/sh
# Fn+F1 - Mute/Unmute toggle via PipeWire user session

wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle

muted=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | grep -c MUTED)
vol=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{printf "%.0f%%", $2*100}')

if [ "$muted" -gt 0 ]; then
    echo "Volume: ${vol:-??%} (muted)" > /tmp/status_msg
else
    echo "Volume: ${vol:-??%}" > /tmp/status_msg
fi
echo $(($(date +%s) + 3)) > /tmp/status_end
