#!/bin/bash

# openvpn-checkconnectionstatus.sh - Check if VPN is connected
# Returns: 0 if connected, 1 if not connected

is_vpn_connected() {
    # Check for openvpn processes using our temp config via ps and grep
    if ps aux | grep -q "[o]penvpn.*/tmp/openvpn_temp"; then
        # Also check for VPN interface
        if ip link show tun0 > /dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

# Main execution
if is_vpn_connected; then
    echo 1
    exit 0
else
    echo 0
    exit 1
fi