#!/bin/bash
# steps/net-watch.sh - NET WATCH (background internet reachability)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"
if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

SOURCE_SCRIPT="$REPO_DIR/scripts/net-watch.sh"

if [ ! -f "$SOURCE_SCRIPT" ]; then
    echo "ERROR: $SOURCE_SCRIPT not found in the installer repo."
    exit 1
fi

echo "Installing Net Watch background tool..."

cp "$SOURCE_SCRIPT" /usr/local/bin/net-watch
chmod +x /usr/local/bin/net-watch

ln -sf /usr/local/bin/net-watch /usr/local/bin/net-watch.sh 2>/dev/null || true

echo "  Installed: /usr/local/bin/net-watch"

echo "  (background watcher auto-started by dwl-start at login)"

echo "  It writes UP/DOWN to /tmp/net_status_\$(id -u) so the status bar can cheaply show reachability."

exit 0
