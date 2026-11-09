#!/bin/bash
# steps/display-hang-catcher.sh - INSTALL + START THE DISPLAY STALL COLLECTOR
#
# Installs scripts/display-hang-catcher.sh as /usr/local/bin/display-hang-catcher,
# starts it from /etc/rc.d/rc.local, and starts it right now.
#
# The collector is passive: it reads /dev/kmsg, /proc and /sys, and writes one
# directory per stall under /var/log. It never signals, dumps or resets
# anything. Why it exists: doc/display-freeze.md — "flip_done timed out" says a
# display commit did not finish, but not which wait hung, and guessing is how
# working power features get disabled for the wrong reason.
#
# Idempotent: reinstalls only when the source differs, adds the rc.local line
# only when absent, and does not start a second instance.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "DISPLAY HANG CATCHER"
echo "*****************************************************"

ok=true
SRC="$REPO_DIR/scripts/display-hang-catcher.sh"
DEST="/usr/local/bin/display-hang-catcher"

if [ ! -f "$SRC" ]; then
    echo "ERROR: $SRC missing"
    exit 1
fi

# 1. Install the script (only when it changed).
if [ -f "$DEST" ] && cmp -s "$SRC" "$DEST"; then
    echo "  $DEST already up to date"
else
    install -m 755 "$SRC" "$DEST" && echo "  installed $DEST"
fi

# 2. Start it at boot from rc.local (BSD init: no systemd units here).
RC_LOCAL="/etc/rc.d/rc.local"
if [ ! -f "$RC_LOCAL" ]; then
    if [ -f "$REPO_DIR/dotfiles/system/rc.local" ]; then
        cp "$REPO_DIR/dotfiles/system/rc.local" "$RC_LOCAL" 2>/dev/null || true
        echo "  created $RC_LOCAL from dotfiles/system/rc.local"
    else
        printf '#!/bin/sh\n' > "$RC_LOCAL"
        echo "  created bare $RC_LOCAL"
    fi
fi
# setsid: rc.local's shell exits right after this, and a background child of a
# dying session can take a SIGHUP — which is how the first deployed line ended
# up with no catcher running at all.
START_LINE="setsid /usr/local/bin/display-hang-catcher >/dev/null 2>&1 &"
if grep -q '^setsid /usr/local/bin/display-hang-catcher' "$RC_LOCAL" 2>/dev/null; then
    echo "  rc.local already starts it (setsid)"
elif grep -q '^/usr/local/bin/display-hang-catcher' "$RC_LOCAL" 2>/dev/null; then
    sed -i 's|^/usr/local/bin/display-hang-catcher.*$|setsid /usr/local/bin/display-hang-catcher >/dev/null 2>\&1 \&|' "$RC_LOCAL"
    echo "  upgraded the rc.local start line to setsid"
else
    printf '%s\n' "$START_LINE" >> "$RC_LOCAL"
    echo "  added start line to rc.local"
fi
chmod +x "$RC_LOCAL" 2>/dev/null || true

# 3. Start it now, unless it is already running. The pidfile is authoritative:
#    pattern-matching pgrep -f here once matched this very step script (its path
#    ends in display-hang-catcher.sh), so the daemon never got started.
PIDFILE="/run/display-hang-catcher.pid"
running_pid() {
    local pid
    [ -r "$PIDFILE" ] || return 1
    pid=$(cat "$PIDFILE" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q 'display-hang-catcher' || return 1
    echo "$pid"
}
if RUNPID=$(running_pid); then
    echo "  already running:"
    ps -o pid=,etime=,args= -p "$RUNPID" | sed 's/^/    /'
else
    nohup setsid "$DEST" >/dev/null 2>&1 &
    sleep 1
    if RUNPID=$(running_pid); then
        echo "  started:"
        ps -o pid=,etime=,args= -p "$RUNPID" | sed 's/^/    /'
    else
        echo "  ERROR: failed to start"
        ok=false
    fi
fi

# REMOVE mode: retire the collector (used once the display fix is in the kernel
# and the collector has no job left). Existing dumps are kept.
if [ "${REMOVE:-0}" = "1" ]; then
    if [ -f "$RC_LOCAL" ] && grep -q 'display-hang-catcher' "$RC_LOCAL" 2>/dev/null; then
        grep -v 'display-hang-catcher' "$RC_LOCAL" > "$RC_LOCAL.new" && mv "$RC_LOCAL.new" "$RC_LOCAL"
        echo "  removed the start line from rc.local"
    fi
    PIDF="/run/display-hang-catcher.pid"
    if [ -r "$PIDF" ]; then
        p=$(cat "$PIDF" 2>/dev/null)
        if [ -n "$p" ] && grep -q 'display-hang-catcher' "/proc/$p/cmdline" 2>/dev/null; then
            kill "$p" 2>/dev/null && echo "  stopped the running collector (pid $p)"
        fi
        rm -f "$PIDF"
    fi
    rm -f "$DEST" && echo "  removed $DEST"
    echo "SUCCESS: display hang catcher removed. Dumps under /var/log/<user>-display-hang-*/ are kept."
    exit 0
fi

# 4. Show the state the humans read: the daemon's own log file.
LOGF="/var/log/${USER:-root}-display-hang.log"
if [ -f "$LOGF" ]; then
    echo "  log: $LOGF"
    tail -3 "$LOGF" | sed 's/^/    /'
else
    echo "  WARNING: no log yet at $LOGF"
    ok=false
fi

if $ok; then
    echo "SUCCESS: display hang catcher running (dumps go to /var/log/<user>-display-hang-*/)."
    exit 0
else
    echo "ERROR: display hang catcher incomplete (see messages above)."
    exit 1
fi
