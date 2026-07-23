#!/bin/bash
# steps/wifi-manager.sh - WIFI MANAGER (interactive tool)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"
if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "WIFI MANAGER (interactive tool)"
echo "*****************************************************"

ok=true
echo "Installing WiFi Manager tool..."

# The actual manager script lives in scripts/ in the repo
SOURCE_SCRIPT="$REPO_DIR/scripts/wifi-manager.sh"

if [ ! -f "$SOURCE_SCRIPT" ]; then
    echo "ERROR: $SOURCE_SCRIPT not found in the installer repo."
    exit 1
fi
# Install as a system command
if ! cp "$SOURCE_SCRIPT" /usr/local/bin/wifi-manager; then
    echo "ERROR: Failed to copy wifi-manager to /usr/local/bin/"
    ok=false
fi
if $ok; then
    chmod +x /usr/local/bin/wifi-manager
    echo "  Copied $SOURCE_SCRIPT -> /usr/local/bin/wifi-manager"
    # Convenience symlink
    ln -sf /usr/local/bin/wifi-manager /usr/local/bin/wifi-manager.sh 2>/dev/null || true
fi

if $ok; then
    echo ""
    echo "SUCCESS: WiFi Manager installed to /usr/local/bin/wifi-manager"
    echo "  Run it with:  wifi-manager   (or the short alias: wifi )"
    exit 0
else
    echo "ERROR: WiFi Manager installation failed."
    exit 1
fi
