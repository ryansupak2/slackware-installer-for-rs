#!/bin/bash
# steps/bluetooth-off.sh - DISABLE BLUETOOTH (service + daemon)
#
# Slackware starts bluetoothd from /etc/rc.d/rc.bluetooth when it is executable.
# Clearing the exec bit is the BSD-init way to disable a service: it survives
# reboots, is trivially reversible, and needs no inittab/systemd surgery.
#
# This step only touches the service. Radio state: use `rfkill` —
#   rfkill list          (look for "bluetooth")
#   rfkill block bluetooth   (soft-block, reversible at runtime)
#
# Usage:
#   REPO_DIR=$PWD bash steps/bluetooth-off.sh          # disable + stop now
#   REPO_DIR=$PWD bash steps/bluetooth-off.sh enable   # restore

REPO_DIR="${REPO_DIR:-/root/Development/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

ACTION="${1:-disable}"
RC=/etc/rc.d/rc.bluetooth

echo "*****************************************************"
echo "BLUETOOTH — $ACTION"
echo "*****************************************************"

ok=true

case "$ACTION" in
    disable)
        if [ -f "$RC" ]; then
            chmod -x "$RC" && echo "  $RC is no longer executable (will not start at boot)"
        else
            echo "  $RC not present — nothing to disable"
        fi
        # Stop the running daemon (the user asked for it to be off).
        if [ -x "$RC" ]; then :; fi
        if pgrep -x bluetoothd >/dev/null 2>&1; then
            "$RC" stop >/dev/null 2>&1 || true
            sleep 1
            if pgrep -x bluetoothd >/dev/null 2>&1; then
                echo "  rc.bluetooth stop did not end bluetoothd; leaving it to the next boot"
            else
                echo "  bluetoothd stopped"
            fi
        else
            echo "  bluetoothd not running"
        fi
        ;;
    enable)
        if [ -f "$RC" ]; then
            chmod +x "$RC" && echo "  $RC is executable again (starts at next boot)"
        fi
        "$RC" start >/dev/null 2>&1 || true
        sleep 1
        pgrep -x bluetoothd >/dev/null 2>&1 && echo "  bluetoothd running" || echo "  bluetoothd did not start"
        ;;
    *)
        echo "ERROR: unknown action '$ACTION' (disable|enable)"
        exit 1
        ;;
esac

# Report the facts.
echo "  service file : $([ -f "$RC" ] && stat -c '%A' "$RC" || echo missing)"
echo "  daemon       : $(pgrep -x bluetoothd >/dev/null 2>&1 && echo running || echo not running)"
if command -v rfkill >/dev/null 2>&1; then
    rfk=$(rfkill list bluetooth 2>/dev/null | tr '\n' ' ')
    [ -n "$rfk" ] && echo "  rfkill       : $rfk"
fi

if $ok; then
    echo "SUCCESS: bluetooth $ACTION done."
    exit 0
else
    echo "ERROR: bluetooth $ACTION incomplete."
    exit 1
fi
