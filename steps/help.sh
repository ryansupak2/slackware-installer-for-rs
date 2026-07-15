#!/bin/bash
# steps/help.sh - HELP SCRIPT
# Lightweight step. Now reports SUCCESS for the tally.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"
if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "HELP SCRIPT"
echo "*****************************************************"

ok=true
echo "Copying help script..."
if ! cp "$REPO_DIR/dotfiles/scripts/help.sh" /usr/local/bin/; then
    ok=false
fi
if $ok; then
    chmod +x /usr/local/bin/help.sh
    echo "SUCCESS: Help script installed."
    exit 0
else
    echo "ERROR: failed to copy help script."
    exit 1
fi
