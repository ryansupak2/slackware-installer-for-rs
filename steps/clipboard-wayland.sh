#!/bin/bash
# steps/clipboard-wayland.sh - WAYLAND CLIPBOARD (wl-clipboard: wl-copy + wl-paste)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "WAYLAND CLIPBOARD (wl-copy / wl-paste)"
echo "*****************************************************"

ok=true

echo "Installing wl-clipboard..."
if ! install_sbo "wl-clipboard"; then
    echo "ERROR: failed to install wl-clipboard."
    ok=false
fi

if $ok; then
    echo "SUCCESS: wl-clipboard installed (wl-copy / wl-paste)."
    exit 0
else
    echo "ERROR: Wayland clipboard setup failed."
    exit 1
fi
