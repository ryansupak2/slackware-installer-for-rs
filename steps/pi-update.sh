#!/bin/bash
# steps/pi-update.sh
# Canonical pi update entry point. Updates pi, then re-applies the Kitty
# keyboard protocol flags patch (7 → 5), which prevents the backspace/tab/
# enter/space double-fire bug.
#
# Idempotent: the patch is a no-op if already applied.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "PI UPDATE"
echo "*****************************************************"

echo "pi-update: updating pi..."
if /usr/local/bin/pi update --self 2>&1; then
    echo ""
    echo "pi-update: re-applying Kitty keyboard protocol flags patch (7 → 5)..."
    if bash "$REPO_DIR/lib/patch-pi-kitty-flags.sh" 2>&1; then
        echo ""
        echo "SUCCESS: pi updated and double-input fix re-applied."
        exit 0
    else
        echo "ERROR: patch-pi-kitty-flags.sh failed."
        exit 1
    fi
else
    echo "ERROR: pi update --self failed."
    exit 1
fi
