#!/bin/bash
# steps/user-audio.sh - PER-USER AUDIO/MICROPHONE VERIFICATION
# Verifies the target user can capture audio via the running PipeWire session.
REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "USER AUDIO/MICROPHONE: $TARGET_USER"
echo "*****************************************************"

# ── Sanity checks ────────────────────────────────────────────────────
[ -z "$TARGET_USER" ] && { echo "ERROR: TARGET_USER not set"; exit 1; }
id "$TARGET_USER" >/dev/null 2>&1 || { echo "ERROR: User '$TARGET_USER' does not exist"; exit 1; }

USER_UID=$(id -u "$TARGET_USER")

# Ensure audio group
groups "$TARGET_USER" 2>/dev/null | grep -q '\baudio\b' || {
    echo "  Adding $TARGET_USER to audio group..."
    usermod -aG audio "$TARGET_USER" 2>/dev/null || true
}

# Verify packages exist. NOTE: Slackware ships wireplumber, not the deprecated
# pipewire-media-session — requiring the latter made this step abort every run.
for bin in pipewire wireplumber pipewire-pulse pactl parecord arecord aplay; do
    command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: $bin not found — run audio-volume.sh first"; exit 1; }
done

# ── Use the running PipeWire session (the ALSA device is exclusive to one) ──
ROOT_RT="/run/user/0"
ROOT_HOME=$(eval echo ~root)
export XDG_RUNTIME_DIR="$ROOT_RT"
mkdir -p "$ROOT_RT/pulse" 2>/dev/null || true
chmod 700 "$ROOT_RT" 2>/dev/null || true

wait_for_sock() {   # $1 = socket path, $2 = seconds (default 3)
    i=0
    limit=$(( ${2:-3} * 10 ))
    while [ $i -lt $limit ]; do
        [ -S "$1" ] && return 0
        sleep 0.1
        i=$((i+1))
    done
    return 1
}

# A pipewire whose control socket was unlinked from the filesystem still shows
# up in `ps` and in `ss`, but EVERY client gets ECONNREFUSED — that is the
# classic "sound stopped working after login" state. Only in that provably
# broken case do we ask the respawning supervisor (`daemon -r`) to restart the
# child, which recreates the socket. A healthy session is never touched and a
# socket held by a live process is never `rm`'d — deleting it is precisely
# what produced this breakage in the first place.
if pgrep -x pipewire >/dev/null 2>&1 && [ ! -S "$ROOT_RT/pipewire-0" ]; then
    echo "  Broken PipeWire session (control socket unlinked) — restarting..."
    [ -f "$ROOT_HOME/.run/pipewire.pid" ] && kill "$(cat "$ROOT_HOME/.run/pipewire.pid")" 2>/dev/null || true
    wait_for_sock "$ROOT_RT/pipewire-0" 4 || true
fi

PW_STARTED=false
if ! pgrep -x pipewire >/dev/null 2>&1; then
    echo "  No PipeWire session found — starting one..."
    pipewire &
    PW_STARTED=true
    if ! wait_for_sock "$ROOT_RT/pipewire-0" 3; then
        echo "ERROR: pipewire control socket never appeared"; exit 1
    fi
else
    echo "  Using the running PipeWire session"
fi

# wireplumber (session/policy manager) and pipewire-pulse (PulseAudio compat)
if ! pgrep -x wireplumber >/dev/null 2>&1; then
    wireplumber &
    sleep 0.5
fi
if ! pgrep -x pipewire-pulse >/dev/null 2>&1; then
    pipewire-pulse &
    wait_for_sock "$ROOT_RT/pulse/native" 3 || echo "  WARNING: pipewire-pulse socket not up"
fi

pactl info >/dev/null 2>&1 || echo "  WARNING: pactl cannot talk to the session"

# ── Test mic capture as the target user ────────────────────────────────
echo "  Ensuring capture profile is active..."
# Force duplex profile if not already set (jack detection may show mic as unavailable)
CAPTURE_SOURCE=$(pactl list sources short 2>/dev/null | grep -v monitor | head -1 | awk '{print $2}')
if [ -z "$CAPTURE_SOURCE" ]; then
    CARD_ID=$(pactl list cards short 2>/dev/null | grep alsa | head -1 | awk '{print $1}')
    if [ -n "$CARD_ID" ]; then
        pactl set-card-profile "$CARD_ID" output:analog-stereo+input:analog-stereo 2>/dev/null || true
        pactl set-card-profile "$CARD_ID" output:analog-stereo+input:iec958-stereo 2>/dev/null || true
        sleep 1
        CAPTURE_SOURCE=$(pactl list sources short 2>/dev/null | grep -v monitor | head -1 | awk '{print $2}')
    fi
fi
echo "  Testing microphone capture for $TARGET_USER..."
capture_ok=1
if [ -n "$CAPTURE_SOURCE" ]; then
    su "$TARGET_USER" -c "
        export XDG_RUNTIME_DIR='$ROOT_RT'
        timeout 6 parecord --device='$CAPTURE_SOURCE' /tmp/cap-user-\$USER.wav 2>/dev/null
    "
else
    echo "  No capture source found — cannot test microphone."
fi

CAP_FILE="/tmp/cap-user-$TARGET_USER.wav"
if [ -f "$CAP_FILE" ] && [ "$(stat -c%s "$CAP_FILE" 2>/dev/null)" -gt 100 ]; then
    capture_ok=0
    echo "  Capture OK ($(stat -c%s "$CAP_FILE") bytes recorded)"
else
    echo "  Capture FAILED — empty or missing WAV file"
fi
rm -f "$CAP_FILE" 2>/dev/null

# ── No teardown: the PipeWire session is shared with the desktop session ──
# Killing the daemons here (the old behaviour) left the desktop without audio
# until the next login, so we deliberately leave them running.
if $PW_STARTED; then
    echo "  PipeWire left running for subsequent sessions"
fi

# ── Result ───────────────────────────────────────────────────────────
if [ $capture_ok -eq 0 ]; then
    echo "SUCCESS: Microphone capture verified for $TARGET_USER."
    exit 0
else
    echo "ERROR: Microphone capture failed for $TARGET_USER."
    exit 1
fi
