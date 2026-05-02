#!/bin/bash

# VNC Picker/Command Script
# Usage: vnc [server-name] (e.g., vnc tv for direct connect; no arg for menu)
# Maps server names to host:port and password file paths.

declare -A servers=(
    ["tv"]="10.0.1.14:5900 $HOME/.vnc/passwd"
    # Add more: ["name"]="ip:port $HOME/.vnc/other.passwd"
)

prompt_creds() {
    read -p "Enter username for $name: " VNC_USERNAME
    read -s -p "Enter password for $name: " VNC_PASSWORD
    echo ""  # Newline after silent password input
    export VNC_USERNAME VNC_PASSWORD
}

if [[ $# -eq 1 ]]; then
    # Direct connect mode
    name="$1"
    if [[ -n "${servers[$name]}" ]]; then
        details="${servers[$name]}"
        IFS=' ' read -r host_port passwd_file <<< "$details"
        if [[ ! -f "$passwd_file" ]]; then
            echo "Password file not found: $passwd_file"
            exit 1
        fi
        prompt_creds
        echo "Connecting to $name ($host_port)..."
        vncviewer -passwd "$passwd_file" "$host_port"
    else
        echo "Unknown server: $name"
        exit 1
    fi
else
    # Menu mode
    select_server() {
        echo "Available VNC Servers:"
        local options=()
        for name in "${!servers[@]}"; do
            options+=("$name")
        done
        options+=("Quit")
        
        select choice in "${options[@]}"; do
            case $choice in
                "Quit")
                    echo "Exiting."
                    exit 0
                    ;;
                *)
                    if [[ -n "${servers[$choice]}" ]]; then
                        connect_to_server "$choice"
                        break
                    else
                        echo "Invalid option. Try again."
                    fi
                    ;;
            esac
        done
    }
    
connect_to_server() {
    local name="$1"
    local details="${servers[$name]}"
    local host_port passwd_file
    IFS=' ' read -r host_port passwd_file <<< "$details"
    
    if [[ ! -f "$passwd_file" ]]; then
        echo "Password file not found: $passwd_file"
        return 1
    fi
    
    prompt_creds
    echo "Connecting to $name ($host_port)..."
    vncviewer -passwd "$passwd_file" "$host_port"
}
    
    echo "VNC Server Picker"
    select_server
fi