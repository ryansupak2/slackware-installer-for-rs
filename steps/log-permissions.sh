#!/bin/bash
# steps/log-permissions.sh - ENSURE /var/log IS USER-WRITABLE
#
# Sets /var/log to mode 1777 (sticky, world-writable) so that non-root
# users can create their per-user subdirectories (e.g. /var/log/rs/).
# The sticky bit ensures users can only delete their own files.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "LOG PERMISSIONS: /var/log"
echo "*****************************************************"

CURRENT_MODE=$(stat -c '%a' /var/log 2>/dev/null || echo "000")

if [ "$CURRENT_MODE" = "1777" ]; then
    echo "/var/log already 1777 — nothing to do."
    exit 0
fi

chmod 1777 /var/log
echo "Set /var/log to 1777 (was $CURRENT_MODE)."
echo "SUCCESS: /var/log is now user-writable."
