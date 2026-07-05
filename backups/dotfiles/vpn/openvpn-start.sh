#!/bin/bash

# openvpn-start.sh - Interactive NordVPN OpenVPN connector menu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONNECT_SCRIPT="$SCRIPT_DIR/openvpn-connect.sh"
DISCONNECT_SCRIPT="$SCRIPT_DIR/openvpn-disconnect.sh"
STATUS_SCRIPT="$SCRIPT_DIR/openvpn-checkconnectionstatus.sh"

CONFIG_DIR="/tmp"
UDP_DIR="$CONFIG_DIR/ovpn_udp"

# Check prerequisites
if [ ! -d "$UDP_DIR" ]; then
    echo "Error: NordVPN configs not found in $UDP_DIR"
    echo "Run: cd /tmp && wget https://downloads.nordcdn.com/configs/archives/servers/ovpn.zip && unzip ovpn.zip"
    exit 1
fi

if [ ! -f "/root/nordvpn_auth.txt" ]; then
    echo "Error: Auth file not found: /root/nordvpn_auth.txt"
    echo "Create it with: echo -e 'username\npassword' > /root/nordvpn_auth.txt && chmod 600 /root/nordvpn_auth.txt"
    exit 1
fi

# Main menu
main_menu() {
    while true; do
        clear
        echo "NordVPN OpenVPN Connector"
        echo "========================"

        status=$("$STATUS_SCRIPT")
        if [ "$status" = "1" ]; then
            status_display="Connected"
        else
            status_display="Disconnected"
        fi
        echo "Status: $status_display"
        echo ""

        if [ "$status" = "1" ]; then
            echo "Choose an option:"
            echo "1. Disconnect VPN"
            echo "2. Exit"
            echo ""
            read -p "Enter choice (1-2): " choice

            case $choice in
                1)
                    if "$DISCONNECT_SCRIPT"; then
                        exit 0
                    fi
                    read -p "Press Enter to continue..."
                    ;;
                2)
                    exit 0
                    ;;
                *)
                    echo "Invalid choice"
                    read -p "Press Enter to continue..."
                    ;;
            esac
        else
            echo "Choose an option:"
            echo "1. Connect to Mexico (MX)"
            echo "2. Connect by Country Code"
            echo "3. Exit"
            echo ""
            read -p "Enter choice (1-3): " choice

            case $choice in
                1)
                    if "$CONNECT_SCRIPT" mx; then
                        exit 0
                    fi
                    read -p "Press Enter to continue..."
                    ;;
                2)
                    read -p "Enter 2-letter country code (e.g., us, uk, de): " country
                    country=$(echo "$country" | tr '[:upper:]' '[:lower:]')
                    if [ ${#country} -ne 2 ]; then
                        echo "Invalid country code. Must be 2 letters."
                        read -p "Press Enter to continue..."
                        continue
                    fi

                    if "$CONNECT_SCRIPT" "$country"; then
                        exit 0
                    fi
                    read -p "Press Enter to continue..."
                    ;;
                3)
                    exit 0
                    ;;
                *)
                    echo "Invalid choice"
                    read -p "Press Enter to continue..."
                    ;;
            esac
        fi
    done
}

# Start the menu
main_menu