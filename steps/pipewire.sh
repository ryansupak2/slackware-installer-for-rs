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

# Per-user session: /run/user/<uid>. This step runs as the session user from
# dwm-start, so a hardcoded /run/user/0 made a non-root user's audio point at
# root's runtime directory (permission denied, then a broken session).
# Honor the session's runtime dir (dwm-start falls back to /tmp/runtime-<uid>
# when logind has not created /run/user/<uid>); otherwise use the logind path.
RT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
PWRUN="$HOME/.run"
MYUID=$(id -u)
mkdir -p "$RT" 2>/dev/null || true

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

# Scoped to this user: an unscoped pgrep/pkill as a desktop user would see
# root's daemons, mis-detect them as our own, and try to kill them.
supervisor_pid() { pgrep -u "$MYUID" -f "daemon .*--name=$1 " 2>/dev/null | head -1; }

ensure_supervised() {   # $1 name, $2.. command
    name="$1"; shift
    sup=$(supervisor_pid "$name")
    child=$(pgrep -u "$MYUID" -x "$name" 2>/dev/null | head -1)
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
    # No -B (logind session binding): it did not reliably stop the daemons when X
    # exited, it just left them holding unlinked sockets in an emptied
    # /run/user/<uid>. Liveness is checked above instead.
    daemon -r --pidfiles="$PWRUN" --name="$name" "$@" >/dev/null 2>&1 < /dev/null || true
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
# Only root may rewrite the system config; a user session must just report it.
if [ "$(id -u)" -eq 0 ] && [ -f "$PW_STOCK" ] && [ -f "$PW_LOCAL" ] && ! cmp -s "$PW_STOCK" "$PW_LOCAL"; then
    diff_file="/var/log/${USER:-root}-pipewire-conf-$(date +%Y%m%d-%H%M%S).diff"
    diff -u "$PW_STOCK" "$PW_LOCAL" > "$diff_file" 2>/dev/null || true
    echo "  $PW_LOCAL differs from the packaged default (diff: $diff_file)"
    cp "$PW_STOCK" "$PW_LOCAL"
    echo "  restored $PW_LOCAL from $PW_STOCK"
fi

# ── Deploy the session-time helper BEFORE any early exit ────────────
# dwm-start calls /usr/local/bin/pipewire-ensure on every X start, and that
# script must be the per-user version above. A healthy install-time session
# used to return early and leave the old helper installed forever.
# Only root may write /usr/local/bin; a user-session run is a no-op.
if [ "$(id -u)" -eq 0 ]; then
    if ! cmp -s "$0" /usr/local/bin/pipewire-ensure 2>/dev/null; then
        install -m 755 "$0" /usr/local/bin/pipewire-ensure 2>/dev/null || {
            cp "$0" /usr/local/bin/pipewire-ensure && chmod 755 /usr/local/bin/pipewire-ensure
        }
        echo "  /usr/local/bin/pipewire-ensure updated"
    else
        echo "  /usr/local/bin/pipewire-ensure already current"
    fi
fi

# ── Probe: is the session actually serving clients? ─────────────────
core_ok()  { timeout 4 pw-cli info 0 >/dev/null 2>&1; }
pulse_ok() { timeout 4 pactl info  >/dev/null 2>&1; }

if core_ok && pulse_ok; then
    echo "  PipeWire session already healthy — nothing to do."
    exit 0
fi

mkdir -p "$PWRUN" 2>/dev/null || true
chmod 700 "$RT" 2>/dev/null || true

# ── Reset ───────────────────────────────────────────────────────────
# Needed because /run/user/0 is emptied when the logind session ends (exit X,
# re-enter X) while the audio daemons can survive: the daemon keeps listening
# on an inode whose path no longer exists, so the sockets are unowned and every
# client fails with ECONNREFUSED. Nothing short of a restart fixes that.
# Supervisors are stopped BEFORE their children, otherwise `daemon -r`
# respawns exactly what we are killing.
echo "  audio session is not serving clients — resetting"
for name in pipewire-pulse wireplumber pipewire; do
    for sp in $(pgrep -u "$MYUID" -f "daemon .*--name=$name " 2>/dev/null); do
        kill "$sp" 2>/dev/null || true
    done
    pkill -u "$MYUID" -x "$name" 2>/dev/null || true
done
sleep 1
mkdir -p "$RT/pulse" 2>/dev/null || true
chmod 700 "$RT" 2>/dev/null || true
rm -f "$RT/pipewire-0" "$RT/pipewire-0.lock" "$RT/pipewire-0-manager" \
      "$RT/pipewire-0-manager.lock" "$RT/pulse/native" "$RT/pulse/pid" 2>/dev/null || true

# ── Core ────────────────────────────────────────────────────────────
ensure_supervised pipewire /usr/bin/pipewire
if ! wait_sock "$RT/pipewire-0" 6; then
    echo "ERROR: pipewire control socket never appeared"
    exit 1
fi

# ── Session/policy manager ──────────────────────────────────────────
ensure_supervised wireplumber /usr/bin/wireplumber
for i in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -u "$MYUID" -x wireplumber >/dev/null 2>&1 && break
    sleep 0.1
done

# ── PulseAudio compatibility layer ──────────────────────────────────
ensure_supervised pipewire-pulse /usr/bin/pipewire-pulse
if ! wait_sock "$RT/pulse/native" 6; then
    echo "ERROR: pulse/native socket never appeared"
    exit 1
fi

# ── Verify the session answers ──────────────────────────────────────
for i in $(seq 1 25); do
    pulse_ok && break
    sleep 0.2
done
if ! pulse_ok; then
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
