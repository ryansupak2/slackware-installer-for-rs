#!/bin/bash
# lock-screen.sh — screen locker for dwl (wlock) + dwm (xlock) + TTY (physlock)
# Called from keybinds and from ACPI/elogind hooks (system context, no env).
#
# Strategy:
#   - In-session (Mod+Esc): lock the graphical session:
#       · Wayland (dwl) → wlock
#       · X11 (dwm)     → xlock
#   - System (lid close/sleep): if a graphical session is running, lock it;
#     otherwise, lock TTY consoles with physlock.
#   - physlock's VT acquisition conflicts with the compositor's DRM master,
#     so we never run physlock while a graphical session is active.

# Ensure standard paths (acpid runs with minimal env)
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
# Ensure log directory exists BEFORE redirecting output
LOG_DIR=/root/logs
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
LOG="$LOG_DIR/lock-screen-$(date +%Y%m%d-%H%M%S).log"
exec >> "$LOG" 2>&1

CURRENT_TTY=$(tty 2>/dev/null || echo "none")
echo "$(date) lock-screen: WAYLAND='${WAYLAND_DISPLAY:-none}' DISPLAY='${DISPLAY:-none}' USER=$USER TTY=$CURRENT_TTY dwl=$(pgrep -c dwl 2>/dev/null || echo 0) dwm=$(pgrep -c dwm 2>/dev/null || echo 0) physlock_running=$(pgrep -c physlock 2>/dev/null || echo 0)"

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

# ── In-session call (Mod+Esc from dwl) ─────────────────────────
# Lock the current Wayland session with wlock and block until it exits.
if [ -n "$WAYLAND_DISPLAY" ] && [ -n "$XDG_RUNTIME_DIR" ]; then
    command -v wlock >/dev/null 2>&1 || exit 1
    wlock &
    wait $! 2>/dev/null
    exit 0
fi

# ── In-session call (Mod+Esc from dwm) ─────────────────────────
# Lock the current X11 session with xlock and block until it exits.
if [ -n "$DISPLAY" ] && pgrep dwm >/dev/null 2>&1; then
    if command -v xlock >/dev/null 2>&1; then
        echo "$(date) branch: X11 in-session, using xlock"
        xlock -mode blank -bg black -fg white
        exit 0
    else
        echo "$(date) xlock not found, falling back to physlock"
        try_physlock
        exit 0
    fi
fi

# ── System call (acpid / elogind / manual) ─────────────────────
# If a graphical session (dwl) is running, lock it with wlock.
# Running physlock here would steal the VT from the compositor and
# cause a hard hang (DRM master conflict).
#
# If no graphical session exists, lock TTY consoles with physlock.

if pgrep dwl >/dev/null 2>&1; then
    echo "$(date) branch: dwl detected, trying wlock"

    if ! command -v wlock >/dev/null 2>&1; then
        # wlock not available — fall back to physlock
        echo "$(date) wlock not found, falling back to physlock"
        try_physlock
        exit 0
    fi

    # Lock every active dwl session as its owner
    wlock_started=0
    for dwl_pid in $(pgrep dwl 2>/dev/null); do
        [ "$(cat /proc/$dwl_pid/comm 2>/dev/null)" = "dwl" ] || continue
        dwl_uid=$(awk '/^Uid:/{print $2}' /proc/$dwl_pid/status 2>/dev/null)
        [ -z "$dwl_uid" ] && continue
        dwl_user=$(getent passwd "$dwl_uid" 2>/dev/null | cut -d: -f1)
        [ -z "$dwl_user" ] && continue
        runtime="/run/user/$dwl_uid"
        socket=$(ls "$runtime"/wayland-* 2>/dev/null | head -1)
        [ -n "$socket" ] || continue
        display=$(basename "$socket")
        echo "$(date) starting wlock for $dwl_user on $display"
        su "$dwl_user" -c "env XDG_RUNTIME_DIR=$runtime WAYLAND_DISPLAY=$display wlock" &
        wlock_started=1
    done

    if [ "$wlock_started" -eq 0 ]; then
        # dwl was found but no usable session existed (dying/zombie dwl,
        # or socket already cleaned up). Fall back to physlock.
        echo "$(date) no wlock started (dwl zombie?), falling back to physlock"
        try_physlock
        exit 0
    fi

    # Wait for wlock to finish (unlocking one session releases all)
    echo "$(date) waiting for wlock..."
    wait 2>/dev/null
    echo "$(date) wlock finished"
elif pgrep dwm >/dev/null 2>&1; then
    echo "$(date) branch: dwm detected, trying xlock"
    if command -v xlock >/dev/null 2>&1; then
        # When called from system context, DISPLAY may not be set.
        # Try :0 as default for the running X session.
        export DISPLAY="${DISPLAY:-:0}"
        xlock -mode blank -bg black -fg white &
        wait $! 2>/dev/null
        echo "$(date) xlock finished"
        exit 0
    else
        echo "$(date) xlock not found, falling back to physlock"
        try_physlock
        exit 0
    fi
else
    echo "$(date) branch: no dwl, using physlock"
    # No graphical session — lock TTY consoles with physlock
    if ! try_physlock; then
        echo "$(date) ERROR: failed to start physlock"
    fi
fi

echo "$(date) lock-screen exiting"