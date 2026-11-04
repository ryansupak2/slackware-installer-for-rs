#!/bin/sh
# toggle-vox.sh — VOX toggle (Mod+V) — regular dictation, NO audio dump
#
# Evidence-based startup: polls for voxd process instead of arbitrary sleep.
# Model loads lazily on first use inside voxd, not at daemon startup.
# Lock file prevents races when Mod+V fires twice in quick succession.

LOG_DIR="/var/log"
TOGGLE_LOG="$LOG_DIR/${USER:-root}-vox-toggle.log"
LOCK="$XDG_RUNTIME_DIR/vox-toggle-lock"

log_toggle() { echo "$(date '+%Y-%m-%d %H:%M:%S'): toggle-vox: $*" >> "$TOGGLE_LOG"; }

# Debounce: if lock exists, another toggle is already in flight — skip
if ! mkdir "$LOCK" 2>/dev/null; then
    log_toggle "SKIPPED (lock held — another toggle in flight)"
    exit 0
fi
# Remove lock on exit, with 250ms cooldown to prevent rapid double-toggles
trap 'sleep 0.25; rmdir "$LOCK" 2>/dev/null' EXIT

# Determine current VOX state for clear ON/OFF logging
STATE_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vox_state"
if [ -f "$STATE_FILE" ]; then
    CUR_STATE=$(cat "$STATE_FILE" 2>/dev/null)
else
    CUR_STATE="off"
fi

log_toggle "TRIGGERED (current state: $CUR_STATE)"

PID=$(pgrep -x voxd 2>/dev/null)
if [ -n "$PID" ]; then
    log_toggle "voxd already running (PID=$PID)"
    # Regular dictation: ensure voxd is NOT in dump mode
    if grep -q -- '--dump-audio' /proc/$PID/cmdline 2>/dev/null; then
        log_toggle "restarting voxd without --dump-audio"
        pkill -x voxd 2>/dev/null
        while pgrep -x voxd >/dev/null 2>&1; do sleep 0.05; done
        /usr/local/bin/voxd &
    fi
    if [ "$CUR_STATE" = "loading" ]; then
        log_toggle "SKIPPED (voxd is loading — toggle already in progress)"
        exit 0
    fi
    if [ "$CUR_STATE" = "recording" ] || [ "$CUR_STATE" = "recording+dump" ]; then
        log_toggle ">>> VOX OFF <<<"
    else
        log_toggle ">>> VOX ON <<<"
    fi
    kill -USR1 $(pgrep -x voxd) 2>/dev/null
else
    # Stale state check: if state file says recording but voxd isn't running,
    # something killed it (X restart, crash, OOM). Clean up so next toggle is sane.
    if [ "$CUR_STATE" = "recording" ] || [ "$CUR_STATE" = "recording+dump" ]; then
        log_toggle "stale state '$CUR_STATE' with no voxd process — clearing"
        rm -f "$STATE_FILE"
        CUR_STATE="off"
    fi
    log_toggle "voxd not running — starting daemon"
    log_toggle ">>> VOX ON <<<"
    /usr/local/bin/voxd &
    for i in $(seq 1 50); do
        pgrep -x voxd >/dev/null 2>&1 && break
        sleep 0.02
    done
    if pgrep -x voxd >/dev/null 2>&1; then
        log_toggle "voxd started (PID=$(pgrep -x voxd)) — sending SIGUSR1"
        kill -USR1 $(pgrep -x voxd) 2>/dev/null
    else
        log_toggle "ERROR: voxd failed to start after 1s"
    fi
fi
