#!/bin/sh
# mic-test — quick record + playback test (standalone)
# Usage: mic-test [seconds]

SECS="${1:-3}"

cleanup() {
    pkill -u "$(id -u)" -x pipewire-pulse 2>/dev/null
    pkill -u "$(id -u)" -x wireplumber 2>/dev/null
    pkill -u "$(id -u)" -x pipewire 2>/dev/null
    rm -f /tmp/mic-test.wav
}

XDG_RT="/run/user/$(id -u)"
mkdir -p "$XDG_RT" 2>/dev/null

# Start PipeWire if not running
if ! [ -S "$XDG_RT/pipewire-0" ]; then
    rm -f "$XDG_RT"/pipewire-0 "$XDG_RT"/pipewire-0.lock "$XDG_RT"/pulse/native 2>/dev/null
    rm -f "$XDG_RT"/pipewire-0 "$XDG_RT"/pipewire-0.lock "$XDG_RT"/pulse/native 2>/dev/null
    pipewire &
    PW_PID=$!
    for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.1; [ -S "$XDG_RT/pipewire-0" ] && break; done
    if [ ! -S "$XDG_RT/pipewire-0" ]; then echo "ERROR: pipewire failed to start"; kill $PW_PID 2>/dev/null; exit 1; fi
    pipewire-media-session &
    PM_PID=$!
    for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.2; pactl info >/dev/null 2>&1 && break; done
    if ! pactl info >/dev/null 2>&1; then echo "ERROR: pipewire-media-session failed to start"; kill $PM_PID 2>/dev/null; exit 1; fi
    pipewire-pulse &
    PP_PID=$!
    for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.1; [ -S "$XDG_RT/pulse/native" ] && break; done
    if [ ! -S "$XDG_RT/pulse/native" ]; then echo "ERROR: pipewire-pulse failed to start"; kill $PP_PID 2>/dev/null; exit 1; fi
    MIC_ID=$(wpctl status 2>/dev/null | grep "Built-in Microphone" | awk '{for(i=1;i<=NF;i++) if($i~/^[0-9]+\.$/) {gsub(/\./,"",$i); print $i; exit}}')
    [ -n "$MIC_ID" ] && wpctl set-default "$MIC_ID" 2>/dev/null
    wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0 2>/dev/null
    wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 2>/dev/null
    wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 1.0 2>/dev/null
    wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0 2>/dev/null
fi

echo "Recording ${SECS}s... speak now"
arecord -D pipewire -c 2 -f S16_LE -r 48000 -d "$SECS" /tmp/mic-test.wav 2>/dev/null
sz=$(stat -c%s /tmp/mic-test.wav 2>/dev/null)
echo "Recorded: ${sz} bytes"

max=$(dd if=/tmp/mic-test.wav bs=1 skip=44 2>/dev/null | od -An -t d2 | awk '
{ for(i=1;i<=NF;i++) { v=$i; if(v<0) v=-v; if(v>max) max=v } }
END { print max+0 }
')
echo "Peak level: ${max}/32767"

echo ""
echo "Playing back..."
aplay -D pipewire /tmp/mic-test.wav 2>/dev/null && echo "Done"

rm -f /tmp/mic-test.wav
