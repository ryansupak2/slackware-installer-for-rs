#!/bin/bash

# openvpn-disconnect.sh - Disconnect VPN connection
# Returns: 0 on success, 1 on failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_SCRIPT="$SCRIPT_DIR/openvpn-checkconnectionstatus.sh"

if ! "$STATUS_SCRIPT" > /dev/null; then
    echo "No VPN connection found"
    # Still update status to clear any stale display
    echo "" > /tmp/vpn_status && chmod 666 /tmp/vpn_status
    exit 1
fi

echo "Disconnecting VPN..."
pkill -f "^openvpn "

# Wait for OpenVPN to clean up (interface/routes)
for i in {1..10}; do
    if ! ip link show tun0 > /dev/null 2>&1 && ! ip route | grep -q "via 10\.[1-9][0-9]*\."; then
        break
    fi
    sleep 1
done

echo "VPN disconnected successfully!"
# Update status display
echo "" > /tmp/vpn_status && chmod 666 /tmp/vpn_status
exit 0