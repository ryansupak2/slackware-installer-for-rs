#!/bin/bash
# steps/htop.sh - htop
# Simple utility install step.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "htop                                                 "
echo "*****************************************************"

echo "Installing htop..."
if ! install_pkg "htop"; then
    echo "ERROR: htop install failed."
    exit 1
fi

echo "SUCCESS: htop installed."
exit 0
