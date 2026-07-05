#!/bin/bash
# steps/wifi-manager.sh - WIFI MANAGER (interactive tool)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"
if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi


echo "Installing WiFi Manager tool..."

# The actual manager script lives in scripts/ in the repo
SOURCE_SCRIPT="$REPO_DIR/scripts/wifi-manager.sh"

if [ ! -f "$SOURCE_SCRIPT" ]; then
    echo "ERROR: $SOURCE_SCRIPT not found in the installer repo."
    exit 1
fi

# Install as a system command (so it is available to all users + root)
cp "$SOURCE_SCRIPT" /usr/local/bin/wifi-manager || { echo "ERROR: Failed to copy wifi-manager to /usr/local/bin/"; exit 1; }
chmod +x /usr/local/bin/wifi-manager
echo "  Copied $SOURCE_SCRIPT -> /usr/local/bin/wifi-manager"

# Convenience symlink (people sometimes type the .sh)
ln -sf /usr/local/bin/wifi-manager /usr/local/bin/wifi-manager.sh 2>/dev/null || true
# Aliases are deployed by bootstrap.sh (root bashrc) and post-install-user.sh (user bashrc)

echo ""
echo "SUCCESS: WiFi Manager installed to /usr/local/bin/wifi-manager"
echo "  Run it with:  wifi-manager   (or the short alias: wifi )"
exit 0
