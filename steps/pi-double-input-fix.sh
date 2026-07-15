#!/bin/bash
# steps/pi-double-input-fix.sh
# Idempotent fix for pi's backspace/tab/enter double-fire bug.
#
# Reduces Kitty keyboard protocol flags 7 → 5 (drops flag 2 "report event types").
# This prevents terminals from sending keyup events for backspace/tab/enter
# at the protocol level — no dedup, no timers, no cleverness.
#
# Idempotent and version-resilient. Safe to re-run after pi updates.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "PI DOUBLE-INPUT FIX"
echo "*****************************************************"

echo "pi-double-input-fix: applying Kitty protocol flags fix (7 → 5)..."
if bash "$REPO_DIR/lib/patch-pi-kitty-flags.sh"; then
    echo "SUCCESS: pi double-input fix applied."
    exit 0
else
    echo "ERROR: pi double-input fix failed."
    exit 1
fi
