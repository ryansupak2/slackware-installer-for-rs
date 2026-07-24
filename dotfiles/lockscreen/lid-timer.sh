#!/bin/bash
# lid-timer.sh: fires on lid close, waits 10s, then suspends.
# Screen locking is delegated entirely to lock-screen.sh (slock).

LOG_DIR="/var/log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/${USER:-root}-slock-sleep-$(date +%Y%m%d-%H%M%S).log"

lid_state() {
    cat /proc/acpi/button/lid/*/state 2>/dev/null | grep -q 'closed'
}

# Wait up to 10 seconds; if lid reopens, abort
for i in $(seq 1 10); do
    if ! lid_state; then
        echo "$(date) lid reopened, aborting" >> "$LOG"
        exit 0
    fi
    sleep 1
done

echo "$(date) lid stayed closed, suspending" >> "$LOG"

# Gracefully toggle VOX OFF before suspend so state is clean on resume.
# Sends SIGUSR1 to voxd (same as Mod+V) which triggers graceful shutdown:
# flushes final transcription, cleans state file, drops ALSA.
if pgrep -x voxd >/dev/null 2>&1; then
    VOX_STATE=$(cat "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vox_state" 2>/dev/null)
    if [ "$VOX_STATE" = "recording" ] || [ "$VOX_STATE" = "recording+dump" ]; then
        echo "$(date) pre-suspend: toggling vox OFF (was $VOX_STATE)" >> "$LOG"
        kill -USR1 $(pgrep -x voxd) 2>/dev/null
        # Give voxd time to flush final transcription and clean state
        for i in $(seq 1 30); do
            if [ ! -f "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vox_state" ]; then
                echo "$(date) pre-suspend: vox state cleaned after $((i*100))ms" >> "$LOG"
                break
            fi
            usleep 100000
        done
    fi
fi

loginctl suspend || true

# --- POST-RESUME ---
echo "$(date) RESUMED" >> "$LOG"
/usr/local/bin/lock-screen.sh >> "$LOG" 2>&1 &
