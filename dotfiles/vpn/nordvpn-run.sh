#!/bin/bash

# nordvpn-run.sh - Interactive NordVPN management script
# Default country: Mexico

DEFAULT_COUNTRY="Mexico"

# Function to get VPN status
get_status() {
    nordvpn status | grep "Status:" | awk '{print $2}'
}

# Main logic
status=$(get_status)

if [ "$status" = "Connected" ]; then
    current_country=$(nordvpn status | grep "Country:" | awk '{print $2}')
    echo "NordVPN is currently connected to $current_country."
    PS3="Choose an option: "
    options=("Disconnect" "Exit")
    select opt in "${options[@]}"
    do
        case $opt in
            "Disconnect")
                /usr/local/bin/nordvpn-disconnect.sh

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
        /usr/local/bin/nordvpn-connect.sh "$1"
    else
        while true; do
            PS3="Choose an option: "
            options=("Connect to $DEFAULT_COUNTRY" "Connect to Custom Country" "Exit")
            select opt in "${options[@]}"
            do
                case $opt in
                    "Connect to $DEFAULT_COUNTRY")
                        if /usr/local/bin/nordvpn-connect.sh "$DEFAULT_COUNTRY"; then
                            exit 0
                        fi
                        break
                        ;;
                    "Connect to Custom Country")
                        read -p "Enter country name: " country
                        if /usr/local/bin/nordvpn-connect.sh "$country"; then
                            exit 0
                        fi
                        break
                        ;;
                    "Exit")
                        echo "Exiting."
                        exit 0
                        ;;
                    *)
                        echo "Invalid option. Please choose 1, 2, or 3."
                        break
                        ;;
                esac
            done
        done
    fi
fi