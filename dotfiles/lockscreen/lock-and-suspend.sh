#!/bin/bash
# lock-and-suspend.sh — lid-close handler
#  1. Shut down VOX, lock screen (slock if X11, physlock if TTY)
#  2. Wait 10s: if lid reopens, kill lock and abort
#  3. Suspend
#  4. After resume: kill stale lockers, re-lock

export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

LOG_DIR="/var/log/sessions"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/${USER:-root}-suspend-$(date +%Y%m%d-%H%M%S).log"
exec >> "$LOG" 2>&1

echo "$(date) lid closed — locking"

# Shut down VOX immediately before locking
if pgrep -x voxd >/dev/null 2>&1; then
    echo "$(date) shutting down vox"
    kill -USR1 $(pgrep -x voxd) 2>/dev/null
    for i in $(seq 1 30); do
        if ! pgrep -x voxd >/dev/null 2>&1; then
            echo "$(date) vox shut down after $((i*100))ms"
            break
        fi
        usleep 100000
    done
fi

# Lock (lock-screen.sh chooses slock for X11, physlock for TTY)
/usr/local/bin/lock-screen.sh &
LOCK_PID=$!

lid_closed() {
	cat /proc/acpi/button/lid/*/state 2>/dev/null | grep -q 'closed'
}

# Wait up to 10 seconds; if lid reopens, abort
for i in $(seq 1 10); do
	if ! lid_closed; then
		echo "$(date) lid reopened — aborting suspend"
		kill $LOCK_PID 2>/dev/null || true
		wait $LOCK_PID 2>/dev/null
		exit 0
	fi
	sleep 1
done

echo "$(date) lid stayed closed — suspending (sleep state: $(cat /sys/power/mem_sleep 2>/dev/null | grep -o '\[.*\]' || echo unknown))"
loginctl suspend || true

# --- After resume ---
echo "$(date) RESUMED (wakeup: $(cat /sys/power/wakeup_type 2>/dev/null || echo unknown))"

# Kill stale lockers (X connection broke for slock, VT state may be stale for physlock)
pkill -x slock 2>/dev/null || true
pkill -x physlock 2>/dev/null || true
sleep 0.5

# Re-lock
/usr/local/bin/lock-screen.sh &
wait $!

echo "$(date) unlocked, exiting"
