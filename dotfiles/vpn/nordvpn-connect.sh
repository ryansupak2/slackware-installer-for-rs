#!/bin/bash

# nordvpn-connect.sh - Script to connect to NordVPN

# Ensure NordVPN service is running
if ! nordvpn status > /dev/null 2>&1; then
    echo "Starting NordVPN service..."
    chmod +x /etc/rc.d/rc.nordvpn
    /etc/rc.d/rc.nordvpn start

fi

# Connect to the specified country or default
country="${1:-Mexico}"

# Handle common country aliases
case "$country" in
  "USA"|"usa"|"America"|"america"|"United States"|"united states") country="United_States" ;;
  # Add more aliases here if needed
esac
echo "Connecting to $country..."
setsid nordvpn connect "$country" >/dev/null 2>&1 &
sleep 3
if nordvpn status | grep -q "Connected"; then
    echo "Connected successfully."
    echo "[VPN] " > /tmp/vpn_status
else
    echo "Connection failed."
    exit 1
fi