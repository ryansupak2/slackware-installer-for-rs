#!/bin/bash
# steps/pipewire.sh - PIPEWIRE SESSION (ensure / repair)
#
# Guarantees a WORKING PipeWire session for the desktop user and repairs the
# failure modes that silently kill audio:
#
#   1. Stale socket files — pipewire-0 / pulse/native on disk but owned by no
#      process: every client fails with "Connection refused".
#   2. Unlinked control socket — pipewire alive but its socket file deleted (an
#      older dwm-start/user-audio step did `rm -f pipewire-0` on a live
#      session); the daemon keeps listening on the unlinked inode, so clients
#      get ECONNREFUSED forever. Only a restart can recreate it.
#   3. Wedged pipewire-pulse — an instance started while no core existed accepts
#      connections but never answers (pactl just hangs).
#   4. Stale supervisors — `daemon -r` can end up alive with no child, so
#      nothing ever comes back.
#
# Idempotent: if `pactl info` already answers, the step does nothing at all.
# It never unlinks a socket that a live process owns.
#
# NOTE: every pactl/wpctl call is wrapped in `timeout` — an unbounded pactl on a
# wedged session blocks forever and hangs the installer.

REPO_DIR="${REPO_DIR:-/root/Development/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "PIPEWIRE SESSION"
echo "*****************************************************"

RT="/run/user/0"
PWRUN="$HOME/.run"

export XDG_RUNTIME_DIR="$RT"
export PULSE_SERVER="unix:$RT/pulse/native"

# Always bounded — a wedged session makes pactl block indefinitely.
session_ok() { timeout 4 pactl info >/dev/null 2>&1; }

wait_sock() {   # $1 socket, $2 seconds (default 4)
    i=0
    limit=$(( ${2:-4} * 10 ))
    while [ $i -lt $limit ]; do
        [ -S "$1" ] && return 0
        sleep 0.1
        i=$((i+1))
    done
    return 1
}

supervisor_pid() { pgrep -f "daemon -rB .*--name=$1 " 2>/dev/null | head -1; }

ensure_supervised() {   # $1 name, $2.. command
    name="$1"; shift
    sup=$(supervisor_pid "$name")
    child=$(pgrep -x "$name" 2>/dev/null | head -1)
    if [ -n "$sup" ] && [ -n "$child" ]; then
        echo "  $name: supervised (pid $child) — ok"
        return 0
    fi
    if [ -n "$sup" ] && [ -z "$child" ]; then
        echo "  $name: supervisor $sup has no child — restarting supervisor"
        kill "$sup" 2>/dev/null || true
        sleep 0.4
    elif [ -z "$sup" ] && [ -n "$child" ]; then
        echo "  $name: running unsupervised (pid $child) — moving it under a supervisor"
        kill "$child" 2>/dev/null || true
        sleep 0.6
    fi
    echo "  $name: starting supervised..."
    daemon -rB --pidfiles="$PWRUN" --name="$name" "$@" >/dev/null 2>&1 < /dev/null || true
    return 0
}

# ── 0. Configuration must be the packaged default ────────────────┐
# A malformed /etc/pipewire/pipewire.conf makes PipeWire drop its whole
# context.modules array ("pw.conf | malformed object array"): the daemons then
# run, the sockets exist, and every client hangs or gets ECONNREFUSED.
# `pw-config` does NOT catch this (it still prints the module list), so the
# only reliable rule is: the override must match the packaged default.
# Nothing in the default needs "enabling" — wireplumber creates the ALSA
# devices. Any difference is either stale damage from the old line-number
# seds or an intentional local edit; both are reported.
PW_STOCK=/usr/share/pipewire/pipewire.conf
PW_LOCAL=/etc/pipewire/pipewire.conf
if [ -f "$PW_STOCK" ] && [ -f "$PW_LOCAL" ] && ! cmp -s "$PW_STOCK" "$PW_LOCAL"; then
    diff_file="/var/log/${USER:-root}-pipewire-conf-$(date +%Y%m%d-%H%M%S).diff"
    diff -u "$PW_STOCK" "$PW_LOCAL" > "$diff_file" 2>/dev/null || true
    echo "  $PW_LOCAL differs from the packaged default (diff: $diff_file)"
    cp "$PW_STOCK" "$PW_LOCAL"
    echo "  restored $PW_LOCAL from $PW_STOCK"
fi

# ── Already healthy? Nothing to do. ─────────────────────────────────
if session_ok; then
    echo "  PipeWire session already healthy — nothing to do."
    exit 0
fi

mkdir -p "$RT/pulse" "$PWRUN" 2>/dev/null || true
chmod 700 "$RT" 2>/dev/null || true

# ── 1. Remove stale sockets (only when no process owns them) ────────
if ! pgrep -x pipewire >/dev/null 2>&1; then
    for s in pipewire-0 pipewire-0.lock pipewire-0-manager pipewire-0-manager.lock; do
        [ -e "$RT/$s" ] && rm -f "$RT/$s" && echo "  removed stale $s (no owner)"
    done
fi
if ! pgrep -x pipewire-pulse >/dev/null 2>&1; then
    for s in pulse/native pulse/pid; do
        [ -e "$RT/$s" ] && rm -f "$RT/$s" && echo "  removed stale $s (no owner)"
    done
fi

# ── 2. Alive but socket unlinked → let the supervisor respawn it ────
if pgrep -x pipewire >/dev/null 2>&1 && [ ! -S "$RT/pipewire-0" ]; then
    echo "  broken session: pipewire alive but control socket is gone"
    if [ -f "$PWRUN/pipewire.pid" ]; then
        kill "$(cat "$PWRUN/pipewire.pid")" 2>/dev/null || true
    else
        pkill -x pipewire 2>/dev/null || true
    fi
    sleep 1
fi

# ── 3. Core ─────────────────────────────────────────────────────────
ensure_supervised pipewire /usr/bin/pipewire
if ! wait_sock "$RT/pipewire-0" 5; then
    echo "ERROR: pipewire control socket never appeared"
    exit 1
fi

# ── 4. Session/policy manager ───────────────────────────────────────
ensure_supervised wireplumber /usr/bin/wireplumber
for i in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x wireplumber >/dev/null 2>&1 && break
    sleep 0.1
done

# ── 5. PulseAudio compatibility layer ───────────────────────────────
# Bounce instances left over from a core-less session: they accept the
# connection and never answer, so pactl hangs.
if pgrep -x pipewire-pulse >/dev/null 2>&1 && ! session_ok; then
    echo "  wedged pipewire-pulse detected — restarting it"
    pkill -x pipewire-pulse 2>/dev/null || true
    sleep 1
fi
ensure_supervised pipewire-pulse /usr/bin/pipewire-pulse
if ! wait_sock "$RT/pulse/native" 5; then
    echo "ERROR: pulse/native socket never appeared"
    exit 1
fi

# ── 6. Verify the session answers ───────────────────────────────────
for i in $(seq 1 15); do
    session_ok && break
    sleep 0.2
done
if ! session_ok; then
    echo "ERROR: pactl still cannot talk to the session"
    exit 1
fi

# Sane hardware mixer before exposing the sink
if [ -x /usr/local/bin/audio-mixer-fix ]; then
    AUDIO_MIXER_QUIET=1 /usr/local/bin/audio-mixer-fix || true
fi

DEFAULT_SINK=$(timeout 4 pactl list sinks short 2>/dev/null | head -1 | awk '{print $2}')
if [ -n "$DEFAULT_SINK" ]; then
    timeout 4 pactl set-default-sink "$DEFAULT_SINK" 2>/dev/null || true
    echo "  default sink: $DEFAULT_SINK"
else
    echo "  WARNING: no sink exposed — check 'wpctl status'"
fi

echo "  sinks:   $(timeout 4 pactl list sinks short 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
echo "  sources: $(timeout 4 pactl list sources short 2>/dev/null | grep -v monitor | awk '{print $2}' | tr '\n' ' ')"
echo "SUCCESS: PipeWire session is serving clients."
exit 0
