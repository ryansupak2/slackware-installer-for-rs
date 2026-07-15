#!/bin/bash
# steps/midnight-commander.sh - MIDNIGHT COMMANDER (mc)
# This step now participates in the overall SUCCESS/ERROR tally.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "MIDNIGHT COMMANDER (mc)"
echo "*****************************************************"
echo "Installing mc..."

ok=true
install_pkg "mc" || ok=false

if $ok; then
    echo "Configuring mc to prevent hangs..."
    mkdir -p "$HOME/.mc"
    cp "$REPO_DIR/dotfiles/mc/ini" "$HOME/.mc/ini"
    cp "$REPO_DIR/dotfiles/mc/mc.ext" "$HOME/.mc/mc.ext"
    # Slackware mc extension scripts location (common paths)
    MC_EXT_DIR="/usr/share/mc/ext.d"
    mkdir -p "$MC_EXT_DIR"
    cp "$REPO_DIR/dotfiles/mc/sound.sh" "$MC_EXT_DIR/sound.sh" 2>/dev/null || cp "$REPO_DIR/dotfiles/mc/sound.sh" /usr/lib/mc/ext.d/sound.sh 2>/dev/null || true
    cp "$REPO_DIR/dotfiles/mc/video.sh" "$MC_EXT_DIR/video.sh" 2>/dev/null || cp "$REPO_DIR/dotfiles/mc/video.sh" /usr/lib/mc/ext.d/video.sh 2>/dev/null || true
fi

if $ok; then
    echo "SUCCESS: Midnight Commander (mc) installed and configured."
    exit 0
else
    echo "ERROR: Midnight Commander (mc) setup encountered errors."
    exit 1
fi
