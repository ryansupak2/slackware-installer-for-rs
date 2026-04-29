#!/bin/bash

# nordvpn-run.sh - Interactive NordVPN management script
# Default country: Mexico

DEFAULT_COUNTRY="Mexico"

# Function to get VPN status
get_status() {
    nordvpn status | grep "Status:" | awk '{print $2}'
}

# Function to connect to a country
connect_country() {
    local country="$1"
    echo "Connecting to $country..."
    nordvpn connect "$country"
    if [ $? -eq 0 ]; then
        echo "Connected successfully."
    else
        echo "Connection failed."
    fi
}

# Function to disconnect
disconnect_vpn() {
    echo "Disconnecting..."
    nordvpn disconnect
    if [ $? -eq 0 ]; then
        echo "Disconnected successfully."
    else
        echo "Disconnection failed."
    fi
}

# Main logic
status=$(get_status)

if [ "$status" = "Connected" ]; then
    echo "NordVPN is currently connected."
    PS3="Choose an option: "
    options=("Disconnect" "Exit")
    select opt in "${options[@]}"
    do
        case $opt in
            "Disconnect")
                disconnect_vpn
                break
                ;;
            "Exit")
                echo "Exiting."
                break
                ;;
            *)
                echo "Invalid option. Please choose 1 or 2."
                ;;
        esac
    done
else
    echo "NordVPN is currently disconnected."
    if [ $# -gt 0 ]; then
        # Argument provided, connect directly
        connect_country "$1"
    else
        PS3="Choose an option: "
        options=("Connect to $DEFAULT_COUNTRY" "Connect to Custom Country" "Exit")
        select opt in "${options[@]}"
        do
            case $opt in
                "Connect to $DEFAULT_COUNTRY")
                    connect_country "$DEFAULT_COUNTRY"
                    break
                    ;;
                "Connect to Custom Country")
                    read -p "Enter country name: " country
                    connect_country "$country"
                    break
                    ;;
                "Exit")
                    echo "Exiting."
                    break
                    ;;
                *)
                    echo "Invalid option. Please choose 1, 2, or 3."
                    ;;
        esac
        done
    fi
fi