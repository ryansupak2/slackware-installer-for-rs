#!/bin/bash
# lock-screen.sh — lock the screen
#   X11 dwm session:  slock (X overlay, no VT switch)
#   TTY/no-X:         physlock -d (VT-based, asterisk feedback)

export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

LOG_DIR="/var/log/sessions"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/${USER:-root}-lock-screen-$(date +%Y%m%d-%H%M%S).log"
exec >> "$LOG" 2>&1

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

echo "$(date) locking (USER=${USER:-?} DISPLAY=${DISPLAY:-none})"

# X11 dwm is running — use slock
if pgrep dwm >/dev/null 2>&1; then
    # Find the dwm session owner and auth info
    for dwm_pid in $(pgrep dwm 2>/dev/null); do
        [ "$(cat /proc/$dwm_pid/comm 2>/dev/null)" = "dwm" ] || continue
        dwm_uid=$(awk '/^Uid:/{print $2}' /proc/$dwm_pid/status 2>/dev/null)
        [ -z "$dwm_uid" ] && continue
        dwm_user=$(getent passwd "$dwm_uid" 2>/dev/null | cut -d: -f1)
        [ -z "$dwm_user" ] && continue

        dwm_display=$(tr '\0' '\n' < /proc/$dwm_pid/environ 2>/dev/null | grep '^DISPLAY=' | cut -d= -f2-)
        [ -n "$dwm_display" ] || dwm_display=":0"
        dwm_xauth=$(tr '\0' '\n' < /proc/$dwm_pid/environ 2>/dev/null | grep '^XAUTHORITY=' | cut -d= -f2-)
        if [ -z "$dwm_xauth" ]; then
            dwm_home=$(getent passwd "$dwm_uid" 2>/dev/null | cut -d: -f6)
            dwm_xauth="${dwm_home:-/home/$dwm_user}/.Xauthority"
        fi

        echo "$(date) branch: X11, starting slock for $dwm_user on $dwm_display"
        su "$dwm_user" -c "env DISPLAY=$dwm_display XAUTHORITY=$dwm_xauth slock" &
        exit 0
    done
    # dwm found but couldn't lock — fall through to physlock
    echo "$(date) WARNING: dwm detected but could not start slock"
fi

# No X11 — use physlock
if pgrep -x physlock >/dev/null 2>&1; then
    echo "$(date) physlock already running — exiting"
    exit 0
fi

echo "$(date) branch: TTY/no-X, using physlock"
exec physlock -d
