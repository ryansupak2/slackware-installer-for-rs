#!/bin/sh
# Fn+F1 - Mute/Unmute toggle via PipeWire pulse interface

# Source temp-msg helper
if [ -f /usr/local/bin/temp-msg.sh ]; then . /usr/local/bin/temp-msg.sh
else set_temp_msg() { echo "$1" > "$XDG_RUNTIME_DIR/status_msg"; echo $(($(date +%s) + ${2:-4})) > "$XDG_RUNTIME_DIR/status_end"; }; fi

pactl set-sink-mute @DEFAULT_SINK@ toggle 2>/dev/null

muted=$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | grep -oP 'yes|no')
vol=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | head -1 | grep -oP '\d+%' | head -1)
[ -z "$vol" ] && vol="??%"

if [ "$muted" = "yes" ]; then
    set_temp_msg "Volume: ${vol} (muted)"
else
    set_temp_msg "Volume: ${vol}"
fi
