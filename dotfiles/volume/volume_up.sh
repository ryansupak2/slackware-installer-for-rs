#!/bin/sh
# Fn+F3 - Volume Up (raise + unmute) via PipeWire user session

wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ -l 1.5
wpctl set-mute @DEFAULT_AUDIO_SINK@ 0

vol=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{printf "%.0f%%", $2*100}')
echo "Volume: ${vol:-??%}" > /tmp/status_msg
echo $(($(date +%s) + 3)) > /tmp/status_end
