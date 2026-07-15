#!/bin/bash
# steps/sox.sh - AUDIO/DSP: SoX (Sound eXchange — audio processing Swiss Army knife)
# Installs sox (format support is built-in on Slackware).
REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "AUDIO/DSP: SoX (Sound eXchange)"
echo "*****************************************************"
ok=true

# Already installed? (idempotent check)
if command -v sox >/dev/null 2>&1; then
    echo "SoX is already installed ($(sox --version 2>&1 | head -1))."
else
    if ! install_pkg "sox"; then
        ok=false
    fi
fi

if $ok; then
    echo "SUCCESS: SoX installed."
    echo ""
    echo "  Usage examples:"
    echo "    sox input.wav output.mp3         # convert"
    echo "    sox input.wav -n spectrogram     # generate spectrogram"
    echo "    sox input.wav -n stats           # audio stats"
    echo "    rec -d output.wav                # record from default mic"
    echo "    play input.wav                   # play a file"
    exit 0
else
    echo "ERROR: SoX installation failed."
    exit 1
fi
