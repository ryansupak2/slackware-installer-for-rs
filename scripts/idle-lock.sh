#!/bin/sh
# idle-lock.sh — lock the session shortly BEFORE the screen blanks
#
# The point is ordering, not locking as such: dwm-start blanks the panel after
# BLANK_MINUTES (/var/lib/power/state) with `xset s` + DPMS. If we locked only
# after the blank, the panel could come back while the desktop is still on
# screen — the exact flicker we refuse. So this locks LEAD seconds early, and
# then the normal blanking puts the panel to sleep on top of an already locked
# screen. Waking the display can therefore only ever show slock.
#
# BLANK_MINUTES=0 disables blanking in dwm-start, and this watcher with it.
#
# Started from the X session (scripts/dwm-start.sh); it dies with X because
# xidle stops answering.

DISPLAY="${DISPLAY:-:0}"
export DISPLAY
[ -n "${XAUTHORITY:-}" ] && export XAUTHORITY

# Session helpers log to stderr; dwm-start's session log captures it
# (/var/log/<user>-dwm-YYYYMMDD-HHMMSS.log), matching the repo convention.
log() { printf '%s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

LEAD_SECONDS="${IDLE_LOCK_LEAD:-20}"   # lock this long before the blank
POLL_SECONDS=5

# Marker written by slock (see sources/slock/slock.c and lock-screen.sh):
# root -> /run/slock.locked, everyone else -> their own XDG_RUNTIME_DIR.
if [ "$(id -u)" -eq 0 ]; then
    LOCK_MARKER=/run/slock.locked
else
    LOCK_MARKER="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/slock.locked"
fi

blank_minutes=0
if [ -r /var/lib/power/state ]; then
    # shellcheck disable=SC1091
    . /var/lib/power/state 2>/dev/null
    blank_minutes="${BLANK_MINUTES:-0}"
fi
case "$blank_minutes" in ''|*[!0-9]*) blank_minutes=0 ;; esac
if [ "$blank_minutes" -le 0 ]; then
    log "blanking disabled (BLANK_MINUTES=0) — idle lock off"
    exit 0
fi

threshold=$((blank_minutes * 60 - LEAD_SECONDS))
[ "$threshold" -lt 10 ] && threshold=10
log "idle lock armed: lock at ${threshold}s idle (blank at $((blank_minutes * 60))s)"

while :; do
    idle=$(/usr/local/bin/xidle 2>/dev/null) || {
        # X went away (session ending) or the extension is missing
        log "xidle failed — watcher stopping"
        exit 0
    }
    case "$idle" in ''|*[!0-9]*) sleep "$POLL_SECONDS"; continue ;; esac

    if [ "$idle" -ge $((threshold * 1000)) ]; then
        if /usr/local/bin/lock-screen.sh; then
            log "locked after ${idle}ms idle"
            # slock re-arms the idle counter (input is grabbed), so the next
            # iteration would fire again; wait for the unlock instead. The
            # marker is validated each pass: a SIGKILLed slock leaves it behind.
            while [ -r "$LOCK_MARKER" ]; do
                pid=$(cat "$LOCK_MARKER" 2>/dev/null)
                if [ -z "$pid" ] || ! grep -qx 'slock' "/proc/$pid/comm" 2>/dev/null; then
                    rm -f "$LOCK_MARKER"
                    log "stale lock marker removed (slock was killed)"
                    break
                fi
                sleep 2
            done
            log "unlocked — idle timer re-armed"
        else
            log "lock-screen.sh failed (will retry)"
            sleep "$POLL_SECONDS"
        fi
    else
        sleep "$POLL_SECONDS"
    fi
done
