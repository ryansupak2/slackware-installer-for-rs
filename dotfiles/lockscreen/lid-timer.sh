#!/bin/bash
# lid-timer.sh: fires on lid close, waits 10s, then suspends.
# Screen locking is delegated entirely to lock-screen.sh (slock).

LOG_DIR="/root/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/slock-sleep-$(date +%Y%m%d-%H%M%S).log"

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
loginctl suspend || true

# --- POST-RESUME ---
echo "$(date) RESUMED" >> "$LOG"
/usr/local/bin/lock-screen.sh >> "$LOG" 2>&1 &
