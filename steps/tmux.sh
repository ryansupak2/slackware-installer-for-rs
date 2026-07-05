#!/bin/bash
# steps/tmux.sh - install tmux terminal multiplexer

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "TMUX (terminal multiplexer)                          "
echo "*****************************************************"

echo "Installing tmux..."
if ! install_pkg "tmux"; then
    echo "ERROR: tmux install failed."
    exit 1
fi

echo "SUCCESS: tmux installed."
exit 0
