#!/bin/bash

# nordvpn-disconnect.sh - Script to disconnect from NordVPN

echo "Disconnecting..."
sudo nordvpn disconnect
if [ $? -eq 0 ]; then
    sleep 2  # Allow disconnect to complete
    echo "Disconnected successfully."
    sudo /etc/rc.d/rc.nordvpn stop
    sleep 3  # Allow stop to complete fully
    sudo sh -c 'echo "" > /tmp/vpn_status && chmod 666 /tmp/vpn_status'
else
    echo "Disconnection failed."
    exit 1
fi