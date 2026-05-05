#!/bin/bash

# openvpn-connect.sh - Connect to VPN with specified parameters
# Usage: openvpn-connect.sh <country_code>
# Examples: openvpn-connect.sh mx (Mexico), openvpn-connect.sh us (USA)

CONFIG_DIR="/tmp"
UDP_DIR="$CONFIG_DIR/ovpn_udp"
TCP_DIR="$CONFIG_DIR/ovpn_tcp"
AUTH_FILE="/root/nordvpn_auth.txt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_SCRIPT="$SCRIPT_DIR/openvpn-checkconnectionstatus.sh"

# Get a random config for country code
get_config_for_country() {
    local country="$1"
    local protocol="${2:-udp}"
    local dir="$UDP_DIR"
    [ "$protocol" = "tcp" ] && dir="$TCP_DIR"

    # Find files starting with country code
    local files=("$dir"/"$country"*.ovpn)
    if [ ${#files[@]} -eq 0 ]; then
        echo "No configs found for country: $country" >&2
        return 1
    fi

    # Return a random file
    echo "${files[RANDOM % ${#files[@]}]}"
}

# Main execution
if [ $# -ne 1 ]; then
    echo "Usage: $0 <country_code>" >&2
    echo "Examples: $0 mx (Mexico), $0 us (USA)" >&2
    exit 1
fi

country_code="$1"
country_code=$(echo "$country_code" | tr '[:upper:]' '[:lower:]')

# Check if already connected
if "$STATUS_SCRIPT" > /dev/null; then
    echo "VPN is already connected" >&2
    exit 1
fi

# Get config file
config_file=$(get_config_for_country "$country_code")
if [ $? -ne 0 ]; then
    exit 1
fi

# Create temporary config with auth file path
temp_config="/tmp/openvpn_temp_$$.ovpn"

if ! cp "$config_file" "$temp_config"; then
    echo "Failed to create temp config" >&2
    exit 1
fi

# Modify auth directive to use file
if grep -q "^auth-user-pass" "$temp_config"; then
    sed -i 's/^auth-user-pass$/auth-user-pass \/root\/nordvpn_auth.txt/' "$temp_config"
    if [ $? -ne 0 ]; then
        echo "Failed to modify auth directive" >&2
        rm -f "$temp_config"
        exit 1
    fi
else
    echo "Warning: No auth-user-pass directive found in config" >&2
fi

# Verify auth file exists
if [ ! -r "$AUTH_FILE" ]; then
    echo "Auth file not found or not readable: $AUTH_FILE" >&2
    rm -f "$temp_config"
    exit 1
fi

echo "Connecting to VPN for country: $country_code"
openvpn "$temp_config" &
openvpn_pid=$!

sleep 2

if "$STATUS_SCRIPT" > /dev/null; then
    echo "VPN connected successfully!"
    # Update status display
    echo "[VPN] " > /tmp/vpn_status && chmod 666 /tmp/vpn_status
    # Keep temp config for duration of connection
    exit 0
else
    echo "Failed to connect to VPN" >&2
    kill $openvpn_pid 2>/dev/null
    rm -f "$temp_config"
    exit 1
fi