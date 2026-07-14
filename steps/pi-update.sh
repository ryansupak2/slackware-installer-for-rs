#!/bin/bash
# steps/pi-update.sh
# Canonical pi update entry point. Updates pi, then re-applies the Kitty
# keyboard protocol flags patch (7 → 5), which prevents the backspace/tab/
# enter/space double-fire bug.
#
# Idempotent: the patch is a no-op if already applied.

set -euo pipefail

REPO_DIR="${REPO_DIR:-/root/Development/slackware-installer-for-rs}"

echo "pi-update: updating pi..."
/usr/local/bin/pi update --self 2>&1

echo ""
echo "pi-update: re-applying Kitty keyboard protocol flags patch (7 → 5)..."
bash "$REPO_DIR/lib/patch-pi-kitty-flags.sh" 2>&1

echo ""
echo "pi-update: done"
