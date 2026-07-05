#!/bin/bash
# steps/net-watch.sh - NET WATCH (background internet reachability via real pings)
#
# Deploys the asynchronous net watcher (scripts/net-watch.sh) to /usr/local/bin/net-watch.
# The watcher performs pure periodic pings (no route/carrier fallbacks) and writes
# "UP"/"DOWN" to a per-user net_status file.
# The xsetroot status loop (in .xinitrc) reads the file cheaply and never pings itself.
# dwl-status reads the file cheaply and never pings itself.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"
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

# Convenience symlink (in case someone types net-watch.sh)
ln -sf /usr/local/bin/net-watch /usr/local/bin/net-watch.sh 2>/dev/null || true
# Aliases are in dotfiles/shell/bashrc, deployed by bootstrap.sh + post-install-user.sh

echo "  Installed: /usr/local/bin/net-watch"

# Kill any stale net-watch from a previous install (old code, old file paths)
pkill -u "$(id -u)" -f '/usr/local/bin/net-watch' 2>/dev/null || true
sleep 0.3

# Clean stale pidfiles and status files for the current user
rm -f "/tmp/net-watch-$(id -u).pid" "/tmp/net_status_$(id -u)" 2>/dev/null || true
# Start a fresh net-watch for the current user (idempotent: pgrep guard inside)
nohup /usr/local/bin/net-watch > /dev/null 2>&1 &
sleep 1

echo "  Background watcher started. Logs: ~/logs/net-watch-*.log"
echo "  It writes UP/DOWN to /tmp/net_status_\$(id -u) so the status bar can cheaply show reachability."
echo ""

exit 0
