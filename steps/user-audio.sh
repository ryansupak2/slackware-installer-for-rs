#!/bin/bash
# steps/user-audio.sh - PER-USER AUDIO/MICROPHONE VERIFICATION
# Verifies the target user can capture audio via the running PipeWire session.
REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

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

# Verify packages exist
for bin in pipewire wireplumber pipewire-pulse wpctl arecord aplay; do
    command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: $bin not found — run audio-volume.sh first"; exit 1; }
done

# ── Use root's PipeWire session (ALSA hw:0,0 is exclusive to one session) ──
ROOT_RT="/run/user/0"
if [ ! -S "$ROOT_RT/pipewire-0" ]; then
    echo "  No PipeWire session found — starting one..."
    export XDG_RUNTIME_DIR="$ROOT_RT"
    mkdir -p "$ROOT_RT"
    chmod 700 "$ROOT_RT" 2>/dev/null || true
    rm -f "$ROOT_RT"/pipewire-0 "$ROOT_RT"/pipewire-0.lock "$ROOT_RT"/pulse/native 2>/dev/null || true

    pipewire 2>/dev/null &
    while [ ! -S "$ROOT_RT/pipewire-0" ]; do sleep 0.2; done
    wireplumber 2>/dev/null &
    while ! wpctl status 2>/dev/null >/dev/null; do sleep 0.5; done
    pipewire-pulse 2>/dev/null &
    while [ ! -S "$ROOT_RT/pulse/native" ]; do sleep 0.2; done
    PW_STARTED=true
else
    echo "  Using root's PipeWire session"
    PW_STARTED=false
fi

# Give the target user access to root's pipewire sockets
chmod 755 "$ROOT_RT" 2>/dev/null || true
chmod a+rw "$ROOT_RT"/pipewire-0 2>/dev/null || true
chmod -R a+rwX "$ROOT_RT"/pulse 2>/dev/null || true

# ── Test mic capture as the target user ────────────────────────────────
echo "  Testing microphone capture for $TARGET_USER..."
capture_ok=1
su "$TARGET_USER" -c "
    export XDG_RUNTIME_DIR='$ROOT_RT'
    timeout 6 arecord -D pipewire -c 2 -f S16_LE -r 48000 -d 2 /tmp/cap-user-\$USER.wav 2>/dev/null
"

CAP_FILE="/tmp/cap-user-$TARGET_USER.wav"
if [ -f "$CAP_FILE" ] && [ "$(stat -c%s "$CAP_FILE" 2>/dev/null)" -gt 100 ]; then
    capture_ok=0
    echo "  Capture OK ($(stat -c%s "$CAP_FILE") bytes recorded)"
else
    echo "  Capture FAILED — empty or missing WAV file"
fi
rm -f "$CAP_FILE" 2>/dev/null

# ── Teardown (only if we started it) ──────────────────────────────────
if $PW_STARTED; then
    pkill -x pipewire-pulse 2>/dev/null || true
    pkill -x wireplumber   2>/dev/null || true
    pkill -x pipewire      2>/dev/null || true
    rm -f "$ROOT_RT"/pipewire-0 "$ROOT_RT"/pipewire-0.lock "$ROOT_RT"/pulse/native 2>/dev/null || true
fi

# ── Result ───────────────────────────────────────────────────────────
if [ $capture_ok -eq 0 ]; then
    echo "SUCCESS: Microphone capture verified for $TARGET_USER."
    exit 0
else
    echo "ERROR: Microphone capture failed for $TARGET_USER."
    exit 1
fi
