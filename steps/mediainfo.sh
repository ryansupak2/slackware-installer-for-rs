#!/bin/bash
# steps/mediainfo.sh - MEDIAINFO
# Previously had no SUCCESS/ERROR tally. Now participates.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "MEDIAINFO                                            "
echo "*****************************************************"

echo "Installing mediainfo..."
if ! install_sbo "mediainfo"; then
    echo "ERROR: mediainfo install failed."
    exit 1
fi

echo "SUCCESS: mediainfo installed."
exit 0
