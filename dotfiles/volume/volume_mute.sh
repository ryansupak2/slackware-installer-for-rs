#!/bin/sh
amixer set Master toggle
muted=$(amixer get Master | grep -o '\[on\]' || echo 'muted')
vol=$(amixer get Master | grep -o '[0-9]*%' | head -1)
if [ "$muted" = "muted" ]; then
    echo "Volume: $vol (muted)" > /tmp/status_msg
else
    echo "Volume: $vol" > /tmp/status_msg
fi
echo $(($(date +%s) + 3)) > /tmp/status_end