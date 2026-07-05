#!/bin/sh
# Fn+F2 - Volume Down via PipeWire user session

wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- -l 1.5

vol=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{printf "%.0f%%", $2*100}')
echo "Volume: ${vol:-??%}" > /tmp/status_msg
echo $(($(date +%s) + 3)) > /tmp/status_end
