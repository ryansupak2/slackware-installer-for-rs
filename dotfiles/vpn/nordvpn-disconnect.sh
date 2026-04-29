#!/bin/bash

# nordvpn-disconnect.sh - Script to disconnect from NordVPN

echo "Disconnecting..."
nordvpn disconnect
sleep 2  # Allow disconnect to complete before stopping daemon
if [ $? -eq 0 ]; then
    echo "Disconnected successfully."
    /etc/rc.d/rc.nordvpn stop
    sleep 3  # Allow stop to complete fully
    echo "" > /tmp/vpn_status
else
    echo "Disconnection failed."
    exit 1
fi