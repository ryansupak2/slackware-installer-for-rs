#!/bin/bash
# lock-screen.sh — screen locker for dwl (wlock) + TTY consoles (physlock)
# Called from dwl keybinds (has WAYLAND_DISPLAY) and from ACPI/elogind
# hooks (system context, no env).
#
# Strategy:
#   - In-session (Mod+Esc): lock the Wayland session with wlock
#   - System (lid close/sleep): if dwl is running, lock it with wlock;
#     otherwise, lock TTY consoles with physlock.
#   - physlock's VT acquisition conflicts with the compositor's DRM master,
#     so we never run physlock while a graphical session is active.

# Mutex: prevent concurrent runs (ACPI lid + elogind sleep hook can fire
# simultaneously).  mkdir is atomic — only one instance wins.
LOCKDIR=/tmp/lock-screen.mutex
mkdir "$LOCKDIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

# Diagnostic logging (one log per invocation)
LOG="/root/logs/lock-screen-$(date +%Y%m%d-%H%M%S).log"
exec >> "$LOG" 2>&1
echo "$(date) lock-screen: WAYLAND='${WAYLAND_DISPLAY:-none}' USER=$USER dwl=$(pgrep -c dwl 2>/dev/null || echo 0) physlock_running=$(pgrep -c physlock 2>/dev/null || echo 0)"

# ─── In-session call (Mod+Esc from dwl) ─────────────────────────
# Lock the current Wayland session with wlock and block until it exits.
if [ -n "$WAYLAND_DISPLAY" ] && [ -n "$XDG_RUNTIME_DIR" ]; then
    command -v wlock >/dev/null 2>&1 || exit 1
    wlock &
    wait $! 2>/dev/null
    exit 0
fi

# ─── System call (acpid / elogind / manual) ─────────────────────
# If a graphical session (dwl) is running, lock it with wlock.
# Running physlock here would steal the VT from the compositor and
# cause a hard hang (DRM master conflict).
#
# If no graphical session exists, lock TTY consoles with physlock.

if pgrep dwl >/dev/null 2>&1; then
    echo "$(date) branch: dwl detected, trying wlock"
    command -v wlock >/dev/null 2>&1 || {
        # wlock not available — fall back to physlock
        echo "$(date) wlock not found, falling back to physlock"
        command -v physlock >/dev/null 2>&1 && pgrep -x physlock >/dev/null 2>&1 || physlock -d &
        exit 0
    }

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
        command -v physlock >/dev/null 2>&1 && pgrep -x physlock >/dev/null 2>&1 || physlock -d &
        exit 0
    fi

    # Wait for wlock to finish (unlocking one session releases all)
    echo "$(date) waiting for wlock..."
    wait 2>/dev/null
    echo "$(date) wlock finished"
else
    echo "$(date) branch: no dwl, using physlock"
    # No graphical session — lock TTY consoles with physlock
    if command -v physlock >/dev/null 2>&1; then
        if pgrep -x physlock >/dev/null 2>&1; then
            echo "$(date) physlock already running, skipping"
        else
            echo "$(date) starting physlock -d"
            physlock -d &
        fi
    else
        echo "$(date) physlock not found!"
    fi
fi

echo "$(date) lock-screen exiting"
