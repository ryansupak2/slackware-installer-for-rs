#!/bin/bash
# lid-timer.sh: fires on lid close, suspends immediately.
# Screen locking is delegated entirely to lock-screen.sh.

LOG_DIR="/var/log/sessions"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/${USER:-root}-slock-sleep-$(date +%Y%m%d-%H%M%S).log"

echo "$(date) suspending" >> "$LOG"
loginctl suspend || true

# --- POST-RESUME ---
echo "$(date) RESUMED" >> "$LOG"

# Wait for hardware keyboard to be truly ready after S3
# xinput list will show "AT Translated Set 2 keyboard" when the device is up
while ! DISPLAY=:0 xinput list 2>/dev/null | grep -q "AT Translated Set 2 keyboard"; do
    usleep 50000
done

/usr/local/bin/lock-screen.sh >> "$LOG" 2>&1
