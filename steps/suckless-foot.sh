#!/bin/bash
# steps/suckless-foot.sh — FOOT TERMINAL (Wayland-native st equivalent)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "FOOT TERMINAL (Wayland-native terminal emulator)     "
echo "*****************************************************"

ok=true

echo "Installing foot..."
if ! install_sbo "foot"; then
    echo "ERROR: failed to install foot."
    ok=false
fi

if $ok; then
    echo "Deploying foot configuration..."
    mkdir -p /etc/xdg/foot
    cp "$REPO_DIR/dotfiles/foot/foot.ini" /etc/xdg/foot/foot.ini
    echo "  foot.ini deployed to /etc/xdg/foot/foot.ini"
    echo "SUCCESS: foot installed and configured."
    exit 0
else
    echo "ERROR: foot setup encountered errors."
    exit 1
fi
