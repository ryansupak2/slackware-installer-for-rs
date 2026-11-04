#!/bin/bash
# scripts/net-watch.sh
# Background internet reachability watcher.
# Performs periodic *real pings* (pure, no route/carrier fallbacks) and writes
# "UP" or "DOWN" to a per-user net_status file so the status bar can read it cheaply.
# Never blocks the bar; completely asynchronous.
# Launched from .xinitrc (or manually). Idempotent (won't start duplicates).

LOG_DIR="/var/log/${USER:-root}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/netwatch-$(date +%Y%m%d-%H%M%S).log"

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
# Match ONLY real watcher processes: the cmdline of a running watcher ENDS with
# .../net-watch (or net-watch.sh). A plain `pgrep -f 'net-watch'` also matched
# the shell/daemon/pager/editor that merely mentioned the name and killed them
# (that is why starting the watcher from a shell could take the shell down with
# it), so the pattern is anchored and obvious non-writers are skipped.
for opid in $(pgrep -f 'net-watch(\.sh)?$' 2>/dev/null || true); do
    [ "$opid" = "$$" ] && continue
    [ "$opid" = "$PPID" ] && continue
    ouid=$(ps -o uid= -p "$opid" 2>/dev/null | tr -d ' ' || echo 0)
    [ "$ouid" = "$myuid" ] || continue
    oargs=$(ps -o args= -p "$opid" 2>/dev/null)
    case "$oargs" in
        daemon\ *) continue ;;        # the respawning supervisor, not a writer
        *pgrep*|*grep*) continue ;;
    esac
    kill "$opid" 2>/dev/null || true
done
sleep 0.4   # let any previous writers exit and stop touching the status file

# Now do the (improved) pidfile claim. The previous instances have been
 # terminated, so the TOCTOU window is closed for normal flows.
target="1.1.1.1"          # reliable public target (Cloudflare)
ping_count=1
ping_timeout=2            # seconds
interval=2                # seconds between pings (cheap & responsive)

# Debounce: a single dropped packet or a brief WiFi roam used to flip the bar
# to [No Internet] almost instantly. DOWN is now published only after
# down_debounce consecutive failed probes (~20s at interval=2); the badge
# clears again on the first good probe so recovery still looks immediate.
down_debounce=10          # consecutive failed probes before showing DOWN
up_debounce=1             # consecutive good probes before showing UP

# Prevent multiple instances for this user/session.
PIDFILE="/tmp/netwatch-$(id -u).pid"
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

# Initial state. Only seed DOWN when there is no previous state: blindly
# writing DOWN here flashed [No Internet] at every login until the first ping
# came back. The last known state deliberately survives logout/login.
if [ ! -f "$net_status_file" ]; then
    echo "DOWN" > "$net_status_file" 2>/dev/null || true
fi
last_state=$(cat "$net_status_file" 2>/dev/null || echo "")

echo "Watcher active. Pinging $target every ${interval}s. Writing to $net_status_file"
echo "Debounce: DOWN after $down_debounce failed probes, UP after $up_debounce good probe(s)"

fail_streak=0   # consecutive failed probes
up_streak=0     # consecutive good probes

while true; do
    # Pure ping result only. No ip route, no carrier, no /sys checks here.
    if ping -c"$ping_count" -W"$ping_timeout" "$target" >/dev/null 2>&1; then
        up_streak=$((up_streak+1))
        fail_streak=0
    else
        fail_streak=$((fail_streak+1))
        up_streak=0
    fi

    # Publish a state only once the debounce counters confirm it; otherwise
    # leave the previously published value untouched (no strobing).
    current=""
    if [ "$up_streak" -ge "$up_debounce" ]; then
        current="UP"
    elif [ "$fail_streak" -ge "$down_debounce" ]; then
        current="DOWN"
    elif [ -z "$last_state" ]; then
        current="DOWN"   # nothing known yet
    fi

    # Always (re)write so readers see fresh value even if file was removed.
    if [ -n "$current" ]; then
        echo "$current" > "$net_status_file" 2>/dev/null || true
        if [ "$current" != "$last_state" ]; then
            echo "[$(date +'%T')] reachability changed: $current (ups=$up_streak fails=$fail_streak)"
            last_state="$current"
        fi
    fi

    sleep "$interval"
done
