#!/bin/sh
# toggle-vox-record.sh — VOX toggle with audio recording (Mod+Shift+V)
#
# Ensures voxd is running with --dump-audio, then toggles recording.
# Audio saved to /var/log/<user>-vox-YYYYMMDD-HHMMSS.wav
#
# Evidence-based: no arbitrary sleeps, polls for process state.
# Lock file prevents races when Mod+Shift+V fires twice in quick succession.

LOG_FILE="/var/log/${USER:-root}-voxtoggle-$(date +%Y%m%d-%H%M%S).log"
LOCK="$XDG_RUNTIME_DIR/vox-toggle-rec-lock"

log_toggle() { echo "$(date '+%Y-%m-%d %H:%M:%S'): toggle-rec: $*" >> "$LOG_FILE"; }

# Debounce: skip if another toggle is in flight
if ! mkdir "$LOCK" 2>/dev/null; then
    log_toggle "SKIPPED (lock held — another toggle in flight)"
    exit 0
fi
trap 'sleep 0.25; rmdir "$LOCK" 2>/dev/null' EXIT

# Determine current VOX state for clear ON/OFF logging
STATE_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vox_state"
if [ -f "$STATE_FILE" ]; then
    CUR_STATE=$(cat "$STATE_FILE" 2>/dev/null)
else
    CUR_STATE="off"
fi

log_toggle "TRIGGERED (current state: $CUR_STATE)"

VOXD=/usr/local/bin/voxd

if pgrep -x voxd >/dev/null 2>&1; then
    log_toggle "voxd already running (PID=$(pgrep -x voxd))"
    if ! grep -q -- '--dump-audio' /proc/$(pgrep -x voxd)/cmdline 2>/dev/null; then
        # voxd running but WITHOUT --dump-audio — restart it
        log_toggle "restarting voxd with --dump-audio"
        pkill -x voxd 2>/dev/null
        while pgrep -x voxd >/dev/null 2>&1; do sleep 0.05; done
        CUR_STATE="off"
        $VOXD --dump-audio &
        # Evidence-based: wait for daemon to be alive
        for i in $(seq 1 50); do
            pgrep -x voxd >/dev/null 2>&1 && break
            sleep 0.02
        done
    fi
else
    log_toggle "voxd not running — starting daemon with --dump-audio"
    CUR_STATE="off"
    $VOXD --dump-audio &
    for i in $(seq 1 50); do
        pgrep -x voxd >/dev/null 2>&1 && break
        sleep 0.02
    done
fi

if pgrep -x voxd >/dev/null 2>&1; then
    if [ "$CUR_STATE" = "recording" ] || [ "$CUR_STATE" = "recording+dump" ]; then
        log_toggle ">>> VOX OFF (record) <<<"
    else
        log_toggle ">>> VOX ON (record) <<<"
    fi
    kill -USR1 $(pgrep -x voxd) 2>/dev/null
else
    log_toggle "ERROR: voxd not running — cannot toggle"
fi
