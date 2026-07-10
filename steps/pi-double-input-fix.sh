#!/bin/bash
# steps/pi-double-input-fix.sh
# Idempotent fix for pi's backspace/tab/enter double-fire bug.
#
# Reduces Kitty keyboard protocol flags 7 → 5 (drops flag 2 "report event types").
# This prevents terminals from sending keyup events for backspace/tab/enter
# at the protocol level — no dedup, no timers, no cleverness.
#
# Idempotent and version-resilient. Safe to re-run after pi updates.

set -euo pipefail

REPO_DIR="${REPO_DIR:-/root/Development/slackware-installer-for-rs}"

echo "pi-double-input-fix: applying Kitty protocol flags fix (7 → 5)..."
bash "$REPO_DIR/lib/patch-pi-kitty-flags.sh"
echo "pi-double-input-fix: done"
