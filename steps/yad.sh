#!/bin/bash
# steps/yad.sh - YAD (GTK dialog/file chooser)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "YAD (GTK dialog / file chooser)                      "
echo "*****************************************************"

echo "Installing yad..."
if ! install_sbo "yad"; then
    echo "ERROR: yad install failed."
    exit 1
fi

echo "SUCCESS: yad installed."
exit 0
