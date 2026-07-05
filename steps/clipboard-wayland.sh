#!/bin/bash
# steps/clipboard-wayland.sh - WAYLAND CLIPBOARD (wl-clipboard + cliphist)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "WAYLAND CLIPBOARD (wl-clipboard + cliphist daemon)"
echo "*****************************************************"

ok=true

echo "Installing wl-clipboard and cliphist..."
if ! install_sbo "wl-clipboard cliphist"; then
    echo "ERROR: failed to install wl-clipboard and cliphist."
    ok=false
fi

# cliphist persists clipboard content after the source app closes.
# It is started by the session launcher (dwl-start).
if $ok; then
    echo "SUCCESS: Wayland clipboard tools installed."
    echo "  Use wl-copy / wl-paste for scripting."
    echo "  cliphist daemon started by dwl-start (see scripts/dwl-start.sh)."
    exit 0
else
    echo "ERROR: Wayland clipboard setup encountered errors."
    exit 1
fi
