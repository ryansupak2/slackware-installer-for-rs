#!/bin/sh
# lock-screen.sh — lock the X session and DO NOT return until the screen is covered
#
# Exit 0  = slock holds the keyboard/pointer and its window covers the screen
#           (proven by /run/slock.locked, which slock writes only after a
#           successful grab — see sources/slock/slock.c)
# Exit 1  = could not lock (no display, slock failed, timeout)
#
# Callers that must never let unlocked content be seen (suspend/sleep hooks,
# lid handling, idle lock) wait on this script's exit status BEFORE sleeping or
# blanking. That is the whole mechanism behind "on wake you can only ever see
# slock".
#
# Safe to call repeatedly: if slock is already covering the screen it returns
# immediately, so a keybind, a sleep hook and an idle timer can all call it.
#
# Env: DISPLAY (default :0), XAUTHORITY (default: the running X server's -auth
# file, else /root/.Xauthority), LOCK_TIMEOUT (default 5 s).

DISPLAY="${DISPLAY:-:0}"
export DISPLAY

if [ -z "${XAUTHORITY:-}" ]; then
    if [ -r /root/.Xauthority ]; then
        XAUTHORITY=/root/.Xauthority
    else
        # X was started by xinit with -auth /root/.serverauth.NNNN; reuse it.
        auth=$(ps -o args= -C Xorg 2>/dev/null | tr ' ' '\n' | grep -A1 '^-auth$' | tail -1)
        [ -n "$auth" ] && XAUTHORITY=$auth
    fi
fi
export XAUTHORITY

MARKER=/run/slock.locked
TIMEOUT="${LOCK_TIMEOUT:-5}"

slock_running() {   # marker exists AND the pid in it is really slock
    pid=$(cat "$MARKER" 2>/dev/null) || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -r "/proc/$pid/comm" ] || return 1
    grep -qx 'slock' "/proc/$pid/comm" 2>/dev/null || return 1
    return 0
}

# Already locked (marker written after the grabs succeeded)?
if slock_running; then
    exit 0
fi

if ! xdpyinfo >/dev/null 2>&1; then
    echo "lock-screen: cannot reach DISPLAY=$DISPLAY (XAUTHORITY=${XAUTHORITY:-unset})" >&2
    exit 1
fi

/usr/local/bin/slock &
slock_pid=$!

i=0
while [ "$i" -lt $((TIMEOUT * 10)) ]; do
    if slock_running; then
        exit 0
    fi
    # slock died (bad display, dying X server): stop waiting
    kill -0 "$slock_pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
done

echo "lock-screen: slock did not cover the screen within ${TIMEOUT}s" >&2
exit 1
