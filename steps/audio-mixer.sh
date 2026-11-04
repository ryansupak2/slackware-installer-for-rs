#!/bin/bash
# steps/audio-mixer.sh - ALSA MIXER PERSISTENCE / SPEAKER UNMUTE
#
# Fixes the two reasons this machine came up silent on every boot:
#   * /etc/rc.d/rc.alsa not executable  -> rc.M never restored the mixer state
#   * legacy numid-based unmutes        -> they hit unrelated controls on the
#                                          cs42l43/CS35L56 SOF card and actually
#                                          muted the internal speaker
#
# Idempotent: safe to run on every install and on every session start.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "ALSA MIXER (speaker unmute + boot persistence)"
echo "*****************************************************"

if [ ! -d /proc/asound ]; then
    echo "ERROR: no ALSA sound card present."
    exit 1
fi

# Deploy the shared helper (also used by dwm-start)
install -m 755 "$REPO_DIR/scripts/audio-mixer-fix.sh" /usr/local/bin/audio-mixer-fix 2>/dev/null || {
    mkdir -p /usr/local/bin
    cp "$REPO_DIR/scripts/audio-mixer-fix.sh" /usr/local/bin/audio-mixer-fix
    chmod 755 /usr/local/bin/audio-mixer-fix
}

# Apply it
if /usr/local/bin/audio-mixer-fix; then
    echo "SUCCESS: mixer unmuted and persisted (rc.alsa enabled)."
    exit 0
else
    echo "ERROR: mixer not in the expected state — check 'amixer -c0 scontrols'."
    exit 1
fi
