#!/bin/bash
# slsk — Soulseek daemon (slskd) control for the CURRENT user/session
#
# Usage: slsk start | stop | restart | status | log | reset-config
#
# POLICY (decided 2026-11-15): slskd is a SESSION daemon, never a boot service.
#
#   * It runs as the user who started the session, inside that session's elogind
#     cgroup. scripts/dwm-start.sh starts it (`slsk start --session-start`) and
#     its EXIT trap stops it; `session-stop` TERMs it as one of the named
#     per-user daemons; KillUserProcesses=yes (steps/session-cleanup.sh) is the
#     backstop when X dies so hard that no script runs.
#   * So it is gone on logout, on user change, and after an X restart: nothing
#     of one login's Soulseek session is inherited by the next one.
#   * It used to be a system service: created as the system user `slskd`,
#     started from /etc/rc.d/rc.local at boot and controlled through
#     `sudo /etc/rc.d/rc.slskd`. That ran whether or not anyone was logged in,
#     survived every logout, and needed root/wheel to touch — so rs could not
#     use it. Both are gone (the rc script, the rc.local line and the sudoers
#     rule are removed by steps/slskd.sh).
#
# ANY USER can use this, with NO sudo:
#   root  -> its own instance, data in /root/.local/share/slskd
#   rs    -> its own instance, data in /home/rs/.local/share/slskd
# Only one instance runs at a time because the ports are shared (5030 web,
# 50300 Soulseek); a second start reports who is holding the port instead of
# failing silently. The music library and download directory are shared
# (/var/lib/slskd, group `slskd`), so both users see the same collection.
#
# What persists: the per-user database/config (~/.local/share/slskd) and the
# library. What does not: the process.

set -u

SLSKD_BIN="${SLSKD_BIN:-/opt/slskd/slskd}"
CONFIG_TEMPLATE="${SLSKD_CONFIG_TEMPLATE:-/etc/slskd/slskd.yml}"
APP_DIR="${SLSKD_APP_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/slskd}"
CONFIG="$APP_DIR/slskd.yml"

UID_NOW=$(id -u)
USER_NOW=$(id -un)

# Runtime dir for the pidfile. XDG_RUNTIME_DIR is inherited, not guaranteed to
# be OURS: `runuser -u rs` (and a su from root) leaves root's /run/user/0 in
# the environment, and writing there fails. Trust it only if it exists, is
# writable and is owned by this uid; otherwise use our own /run/user/<uid>,
# then a private /tmp dir (an X-less start outside any logind session).
RUNTIME="${XDG_RUNTIME_DIR:-}"
if [ -z "$RUNTIME" ] || [ ! -d "$RUNTIME" ] || [ ! -w "$RUNTIME" ] \
   || [ "$(stat -c %u "$RUNTIME" 2>/dev/null)" != "$UID_NOW" ]; then
    RUNTIME="/run/user/$UID_NOW"
    if [ ! -d "$RUNTIME" ] || [ ! -w "$RUNTIME" ]; then
        RUNTIME="/tmp/runtime-$UID_NOW"
        mkdir -p "$RUNTIME" 2>/dev/null || true
        chmod 700 "$RUNTIME" 2>/dev/null || true
    fi
fi
PIDFILE="$RUNTIME/slskd.pid"

# /var/log is 1777 on this machine (steps/log-permissions.sh); fall back to the
# runtime dir if it is not writable, so a missing log never blocks a start.
LOG="/var/log/$USER_NOW-slskd.log"
if ! { : >>"$LOG"; } 2>/dev/null; then
    LOG="$RUNTIME/slskd.log"
fi

log() { printf '%s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true; }

# ── ports, read from the effective config ────────────────────────────────
config_get() {   # $1 = key, $2 = default
    [ -r "$CONFIG" ] || { printf '%s\n' "$2"; return; }
    v=$(awk -v k="$1" '
        $1 == k":" && $2 ~ /^[0-9]+$/ { print $2; exit }
    ' "$CONFIG" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$v" ;; esac
}
WEB_PORT=$(config_get port 5030)          # `port:` under web:
SLSK_PORT=$(config_get soulseek_port 50300)

port_busy() {    # $1 = port
    if ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; then
        return 0
    fi
    ss -ltn 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" {found=1} END {exit !found}'
}

port_holder() {  # $1 = port — as root this names the process, otherwise ""
    ss -ltnpH "sport = :$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)",pid=\([0-9]*\).*/\1 (pid \2)/p' | head -1
}

# ── is *our* slskd running? ──────────────────────────────────────────────
alive_is_ours() {   # $1 = pid
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ -r "/proc/$1/comm" ] || return 1
    [ "$(cat "/proc/$1/comm" 2>/dev/null)" = slskd ] || return 1
    [ "$(awk '/^Uid:/{print $2; exit}' "/proc/$1/status" 2>/dev/null)" = "$UID_NOW" ] || return 1
    return 0
}

current_pid() {
    if [ -r "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE" 2>/dev/null)
        if alive_is_ours "$pid"; then
            printf '%s\n' "$pid"
            return 0
        fi
        rm -f "$PIDFILE"
    fi
    # pidfile lost (e.g. /run/user cleaned) but the process is still ours
    pid=$(pgrep -u "$UID_NOW" -x slskd 2>/dev/null | head -1)
    if alive_is_ours "$pid"; then
        mkdir -p "$RUNTIME" 2>/dev/null || true
        printf '%s\n' "$pid" >"$PIDFILE" 2>/dev/null || true
        printf '%s\n' "$pid"
        return 0
    fi
    return 1
}

ensure_config() {
    mkdir -p "$APP_DIR" 2>/dev/null || {
        echo "slsk: cannot create $APP_DIR" >&2
        return 1
    }
    chmod 700 "$APP_DIR" 2>/dev/null || true
    if [ -f "$CONFIG" ]; then
        return 0
    fi
    if [ ! -r "$CONFIG_TEMPLATE" ]; then
        echo "slsk: $CONFIG_TEMPLATE is missing — re-run steps/slskd.sh" >&2
        return 1
    fi
    cp "$CONFIG_TEMPLATE" "$CONFIG" || {
        echo "slsk: cannot write $CONFIG" >&2
        return 1
    }
    chmod 600 "$CONFIG" 2>/dev/null || true
    log "created per-user config $CONFIG from $CONFIG_TEMPLATE"
    return 0
}

# ── commands ─────────────────────────────────────────────────────────────
cmd_start() {
    quiet=0
    for a in "$@"; do
        case "$a" in
            --quiet|--session-start) quiet=1 ;;
            -f|--force) ;;
        esac
    done

    if pid=$(current_pid); then
        if [ "$quiet" -eq 1 ]; then
            log "slskd already running (pid $pid) — not started again"
        else
            echo "slskd is already running (pid $pid) — http://localhost:$WEB_PORT"
        fi
        return 0
    fi

    [ -x "$SLSKD_BIN" ] || { echo "slsk: $SLSKD_BIN is missing — run steps/slskd.sh" >&2; return 1; }

    ensure_config || return 1

    web_port=$(config_get port "$WEB_PORT")
    slsk_port=$(config_get soulseek_port "$SLSK_PORT")
    if port_busy "$web_port" || port_busy "$slsk_port"; then
        holder=$(port_holder "$web_port")
        echo "slsk: port $web_port/$slsk_port is already in use${holder:+ by $holder}." >&2
        echo "      slskd from another login session is holding it. Log in as that" >&2
        echo "      user (or wait for that session to end) — it is stopped with" >&2
        echo "      'slsk stop' there, or automatically on logout." >&2
        log "start refused: ports $web_port/$slsk_port busy${holder:+ ($holder)}"
        return 1
    fi

    log "starting slskd as $USER_NOW (app-dir $APP_DIR, web $web_port, soulseek $slsk_port)"
    # setsid: own process group, no SIGHUP when the launching terminal closes.
    # It stays in this login session's elogind cgroup, which is what makes it
    # die with the session.
    #
    # cd into the app dir FIRST: slskd uses the *current directory* as the
    # ASP.NET content root. Started from a directory this user cannot read
    # (measured: `runuser -u rs` left root's cwd), it dies immediately with
    # DirectoryNotFoundException, so the start would be silently useless.
    (   cd "$APP_DIR" 2>/dev/null || cd / || exit 1
        exec setsid "$SLSKD_BIN" --app-dir "$APP_DIR" --config "$CONFIG" \
            --no-logo </dev/null >>"$LOG" 2>&1
    ) &
    bgpid=$!
    printf '%s\n' "$bgpid" >"$PIDFILE" 2>/dev/null || true

    i=0
    while [ "$i" -lt 100 ]; do    # up to 10 s for the process to appear
        if pid=$(current_pid); then
            [ "$pid" = "$bgpid" ] || printf '%s\n' "$pid" >"$PIDFILE" 2>/dev/null || true
            if [ "$quiet" -eq 1 ]; then
                log "slskd started (pid $pid)"
            else
                echo "slskd started (pid $pid) — http://localhost:$web_port"
            fi
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done

    rm -f "$PIDFILE"
    echo "slsk: slskd did not stay running — last lines of $LOG:" >&2
    tail -n 8 "$LOG" 2>/dev/null | sed 's/^/      /' >&2
    log "start FAILED (process exited immediately)"
    return 1
}

cmd_stop() {
    quiet=0
    for a in "$@"; do
        case "$a" in --quiet) quiet=1 ;; esac
    done

    if ! pid=$(current_pid); then
        [ "$quiet" -eq 1 ] || echo "slskd is not running."
        return 0
    fi

    log "stopping slskd (pid $pid)"
    kill -TERM "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 150 ]; do      # up to 15 s: it closes the DB and the network
        alive_is_ours "$pid" || break
        sleep 0.1
        i=$((i + 1))
    done
    if alive_is_ours "$pid"; then
        log "slskd (pid $pid) ignored SIGTERM — SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
        sleep 0.3
    fi
    rm -f "$PIDFILE"
    [ "$quiet" -eq 1 ] || echo "slskd stopped."
    return 0
}

cmd_status() {
    if pid=$(current_pid); then
        echo "slskd is running (pid $pid, user $USER_NOW)"
        echo "  web UI  : http://localhost:$(config_get port "$WEB_PORT")"
        echo "  app dir : $APP_DIR"
        echo "  log     : $LOG"
    else
        echo "slskd is not running (user $USER_NOW)"
        if port_busy "$WEB_PORT"; then
            holder=$(port_holder "$WEB_PORT")
            echo "  note    : port $WEB_PORT is in use${holder:+ by $holder} — another user's session"
        fi
        return 1
    fi
    return 0
}

cmd_reset_config() {
    if [ -f "$CONFIG" ]; then
        rm -f "$CONFIG" && echo "removed $CONFIG — the template is copied at the next start"
    else
        echo "$CONFIG does not exist (nothing to reset)"
    fi
}

usage() {
    cat <<EOF
slsk — Soulseek daemon (slskd) control for the current user

Usage: slsk start | stop | restart | status | log | reset-config

  start          start slskd as YOU, in this login session (also done
                 automatically by dwm-start). Fails clearly if another
                 session's slskd already holds the ports.
  stop           stop YOUR slskd (graceful; the next logout does this too)
  restart        stop + start
  status         is it running, on which port, with which data dir and log
  log            follow the log (~/… if /var/log is not writable)
  reset-config   drop your per-user slskd.yml so the template is copied again

No sudo is needed or used. The process does not survive a logout or a user
change; the music library (/var/lib/slskd) and your database
(~/.local/share/slskd) do.
EOF
}

cmd="${1:-}"
shift 2>/dev/null || true
case "$cmd" in
    start)         cmd_start "$@" ;;
    stop)          cmd_stop "$@" ;;
    restart)       cmd_stop --quiet && cmd_start "$@" ;;
    status)        cmd_status ;;
    log)           tail -n 60 -f "$LOG" ;;
    reset-config)  cmd_reset_config ;;
    ''|-h|--help|help) usage ;;
    *) echo "slsk: unknown command '$cmd' (try 'slsk help')" >&2; exit 2 ;;
esac
