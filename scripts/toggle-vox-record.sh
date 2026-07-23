#!/bin/sh
# toggle-vox-record.sh — VOX toggle with audio recording (Mod+Shift+V)
#
# Ensures voxd is running with --dump-audio, then toggles recording.
# Audio saved to /var/log/<user>-vox-YYYYMMDD-HHMMSS.wav

VOXD=/usr/local/bin/voxd

# Check if voxd is running with --dump-audio
if pgrep -x voxd >/dev/null 2>&1; then
    if ! grep -q -- '--dump-audio' /proc/$(pgrep -x voxd)/cmdline 2>/dev/null; then
        # voxd running but WITHOUT --dump-audio — restart it
        pkill -x voxd 2>/dev/null
        sleep 0.3
        $VOXD --dump-audio &
        sleep 0.5
    fi
else
    # voxd not running — start with --dump-audio
    $VOXD --dump-audio &
    sleep 0.5
fi

# Toggle recording
kill -USR1 $(pgrep -x voxd) 2>/dev/null
