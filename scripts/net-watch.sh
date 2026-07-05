#!/bin/bash
# scripts/net-watch.sh
# Background internet reachability watcher.
# Performs periodic *real pings* (pure, no route/carrier fallbacks) and writes
# "UP" or "DOWN" to a per-user net_status file so the status bar can read it cheaply.
# Never blocks the bar; completely asynchronous.
# Launched from .xinitrc (or manually). Idempotent (won't start duplicates).

LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/net-watch-$(date +%Y%m%d-%H%M%S).log"

# Redirect all output (stdout+stderr) to the log file (append).
# Screen output is not needed for a background watcher.
exec >>"$LOG_FILE" 2>&1

echo "=================================================="
echo "net-watch starting: $(date)"
echo "Log: $LOG_FILE"
echo "=================================================="

net_status_file="/tmp/net_status_$(id -u)"

# ------------------------------------------------------------------
# Take-over singleton (the real fix for post-logout/login strobing).
# After logout the previous net-watch may still be alive (disowned, HUP
 # handler running asynchronously) or its pidfile may have races.
 # When a new X session starts (.xinitrc), we actively kill any other
 # net-watch *for this uid* before we begin writing the net_status file.
 # This guarantees at most one writer at any time, eliminating the rapid
 # UP/DOWN interleaving that produces the [No Internet] strobe in the bar.
 # (The .xinitrc now also guards the launch with pgrep -f, but this belt-
 # and-suspenders inside the watcher itself makes it robust even if net-watch
 # is started manually or from other places.)
myuid=$(id -u 2>/dev/null || echo 0)
for opid in $(pgrep -f 'net-watch' 2>/dev/null || true); do
    if [ "$opid" != "$$" ]; then
        ouid=$(ps -o uid= -p "$opid" 2>/dev/null | tr -d ' ' || echo 0)
        if [ "$ouid" = "$myuid" ]; then
            kill "$opid" 2>/dev/null || true
        fi
    fi
done
sleep 0.4   # let any previous writers exit and stop touching the status file

# Now do the (improved) pidfile claim. The previous instances have been
 # terminated, so the TOCTOU window is closed for normal flows.
target="1.1.1.1"          # reliable public target (Cloudflare)
ping_count=1
ping_timeout=2            # seconds
interval=5                # seconds between pings (cheap & responsive)

# Prevent multiple instances for this user/session.
PIDFILE="/tmp/net-watch-$(id -u).pid"
if [ -f "$PIDFILE" ]; then
    oldpid=$(cat "$PIDFILE" 2>/dev/null || echo 0)
    if [ "$oldpid" -gt 0 ] && kill -0 "$oldpid" 2>/dev/null; then
        echo "Already running (pid $oldpid). Exiting."
        exit 0
    fi
fi
echo $$ > "$PIDFILE"

cleanup() {
    echo "net-watch stopping (pid $$) at $(date)"
    rm -f "$PIDFILE" 2>/dev/null || true   # keep net_status_file (last known state survives logout/login)
    exit 0
}
trap cleanup INT TERM EXIT HUP

# Safe initial state (bar will show this until first ping completes)
echo "DOWN" > "$net_status_file" 2>/dev/null || true

echo "Watcher active. Pinging $target every ${interval}s. Writing to $net_status_file"

last_state=""

while true; do
    # Pure ping result only. No ip route, no carrier, no /sys checks here.
    if ping -c"$ping_count" -W"$ping_timeout" "$target" >/dev/null 2>&1; then
        current="UP"
    else
        current="DOWN"
    fi

    # Always (re)write so readers see fresh value even if file was removed.
    echo "$current" > "$net_status_file" 2>/dev/null || true

    if [ "$current" != "$last_state" ]; then
        echo "[$(date +'%T')] reachability changed: $current"
        last_state="$current"
    fi

    sleep "$interval"
done
