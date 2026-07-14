#!/bin/bash
# lib/pi-wrapper.sh
# Transparent wrapper around the real /usr/local/bin/pi that auto-applies
# the Kitty keyboard protocol fix after every pi update.
#
# Usage: pi-wrapper.sh [args...]
# Set PI_REAL_BIN to override the real pi path (default: /usr/local/bin/pi.real)
# Set PI_PATCH_SCRIPT to override the patch script path
#
# DO NOT invoke this script directly — it is installed as /usr/local/bin/pi
# by steps/pi-double-input-fix.sh.

set -euo pipefail

PI_REAL="${PI_REAL_BIN:-/usr/local/bin/pi.real}"
PI_PATCH="${PI_PATCH_SCRIPT:-/root/Development/slackware-installer-for-rs/lib/patch-pi-kitty-flags.sh}"

# Detect if this is an update command
is_update=false
for arg in "$@"; do
    case "$arg" in
        update|--self|--extensions|--all|--force)
            is_update=true
            ;;
    esac
done

# If first arg is "update", definitely an update
if [ "${1:-}" = "update" ]; then
    is_update=true
fi

# Run the real pi
"$PI_REAL" "$@"
rc=$?

# Auto-patch after any update
if $is_update && [ $rc -eq 0 ]; then
    if [ -x "$PI_PATCH" ]; then
        "$PI_PATCH" 2>&1 | sed 's/^/[auto-fix] /'
    fi
fi

exit $rc
