#!/bin/bash
# lock-screen.sh — screen locker for dwm (slock) + TTY (physlock)
# Called from keybinds and from ACPI/elogind hooks (system context, no env).
#
# Strategy:
#   - In-session (Mod+Esc): lock the graphical session:
#       · X11 (dwm)     → slock
#   - System (lid close/sleep): if a graphical session is running, lock it;
#     otherwise, lock TTY consoles with physlock.
#   - physlock's VT acquisition conflicts with the compositor's DRM master,
#     so we never run physlock while a graphical session is active.

# Ensure standard paths (acpid runs with minimal env)
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
# Ensure log directory exists BEFORE redirecting output
LOG_DIR="/var/log"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# ── PID-file mutex (survives suspend/resume) ─────────────────────
# Unlike mkdir, a PID file lets us detect stale locks from a
# pre-suspend instance that is still holding the mutex after resume.
LOCKFILE=/tmp/lock-screen.lock

if [ -f "$LOCKFILE" ]; then
    oldpid=$(cat "$LOCKFILE" 2>/dev/null)
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
        # A live instance still holds the lock — exit quietly
        exit 0
    fi
    # Stale lock (dead PID or unreadable) — clean it up
    rm -f "$LOCKFILE" 2>/dev/null
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE" 2>/dev/null' EXIT

# Diagnostic logging (one log per invocation)
LOG="$LOG_DIR/${USER:-root}-lock-screen-$(date +%Y%m%d-%H%M%S).log"
exec >> "$LOG" 2>&1

# ── Gracefully toggle VOX OFF before locking ──────────────────────
# Flushes final transcription, cleans state file, drops ALSA.
# Only sends signal if vox is currently recording (safe toggle).
vox_off() {
    if pgrep -x voxd >/dev/null 2>&1; then
        VOX_STATE=$(cat "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vox_state" 2>/dev/null)
        if [ "$VOX_STATE" = "recording" ] || [ "$VOX_STATE" = "recording+dump" ]; then
            echo "$(date) pre-lock: toggling vox OFF (was $VOX_STATE)"
            kill -USR1 $(pgrep -x voxd) 2>/dev/null
            # Give voxd time to flush final transcription and clean state
            for i in $(seq 1 30); do
                if [ ! -f "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vox_state" ]; then
                    echo "$(date) pre-lock: vox state cleaned after $((i*100))ms"
                    break
                fi
                usleep 100000
            done
        fi
    fi
}

# Toggle VOX off before locking so mic isn't hot while screen is locked
vox_off
CURRENT_TTY=$(tty 2>/dev/null || echo "none")
echo "$(date) lock-screen: DISPLAY='${DISPLAY:-none}' USER=$USER TTY=$CURRENT_TTY dwm=$(pgrep -c dwm 2>/dev/null || echo 0) physlock_running=$(pgrep -c physlock 2>/dev/null || echo 0)"

# ── Helper: start physlock if available and not already running ──
try_physlock() {
    if command -v physlock >/dev/null 2>&1; then
        if pgrep -x physlock >/dev/null 2>&1; then
            echo "$(date) physlock already running, skipping"
            return 0
        fi
        echo "$(date) starting physlock -d"
        physlock -d &
        local physlock_pid=$!
        sleep 0.3
        if kill -0 "$physlock_pid" 2>/dev/null; then
            echo "$(date) physlock started (pid $physlock_pid)"
            return 0
        else
            echo "$(date) ERROR: physlock exited immediately (pid $physlock_pid)"
            return 1
        fi
    else
        echo "$(date) physlock not found!"
        return 1
    fi
}

# ── In-session call (Mod+Esc from dwm) ─────────────────────────
# Lock the current X11 session with slock and block until it exits.
if [ -n "$DISPLAY" ] && pgrep dwm >/dev/null 2>&1; then
    if command -v slock >/dev/null 2>&1; then
        echo "$(date) branch: X11 in-session, using slock"
        slock
        exit 0
    else
        echo "$(date) slock not found, falling back to physlock"
        try_physlock
        exit 0
    fi
fi

# ── System call (acpid / elogind / manual) ─────────────────────
# If a graphical session (dwm) is running, lock it with slock.
# Running physlock here would steal the VT from the compositor and
# cause a hard hang (DRM master conflict).
#
# If no graphical session exists, lock TTY consoles with physlock.

if pgrep dwm >/dev/null 2>&1; then
    echo "$(date) branch: dwm detected, trying slock"

    if ! command -v slock >/dev/null 2>&1; then
        echo "$(date) slock not found, falling back to physlock"
        try_physlock
        exit 0
    fi

    # Lock every active dwm session as its owner
    slock_started=0
    for dwm_pid in $(pgrep dwm 2>/dev/null); do
        [ "$(cat /proc/$dwm_pid/comm 2>/dev/null)" = "dwm" ] || continue
        dwm_uid=$(awk '/^Uid:/{print $2}' /proc/$dwm_pid/status 2>/dev/null)
        [ -z "$dwm_uid" ] && continue
        dwm_user=$(getent passwd "$dwm_uid" 2>/dev/null | cut -d: -f1)
        [ -z "$dwm_user" ] && continue

        # Extract DISPLAY and XAUTHORITY from the dwm process environment
        dwm_display=$(tr '\0' '\n' < /proc/$dwm_pid/environ 2>/dev/null | grep '^DISPLAY=' | cut -d= -f2-)
        [ -n "$dwm_display" ] || dwm_display=":0"
        dwm_xauth=$(tr '\0' '\n' < /proc/$dwm_pid/environ 2>/dev/null | grep '^XAUTHORITY=' | cut -d= -f2-)
        if [ -z "$dwm_xauth" ]; then
            dwm_home=$(getent passwd "$dwm_uid" 2>/dev/null | cut -d: -f6)
            dwm_xauth="${dwm_home:-/home/$dwm_user}/.Xauthority"
        fi

        echo "$(date) starting slock for $dwm_user on $dwm_display"
        su "$dwm_user" -c "env DISPLAY=$dwm_display XAUTHORITY=$dwm_xauth slock" &
        slock_started=1
    done

    if [ "$slock_started" -eq 0 ]; then
        echo "$(date) no slock started (dwm zombie?), falling back to physlock"
        try_physlock
        exit 0
    fi

    # Wait for slock to finish
    echo "$(date) waiting for slock..."
    wait 2>/dev/null
    echo "$(date) slock finished"
    exit 0
else
    echo "$(date) branch: no dwm, using physlock"
    # No graphical session — lock TTY consoles with physlock
    if ! try_physlock; then
        echo "$(date) ERROR: failed to start physlock"
    fi
fi

echo "$(date) lock-screen exiting"
