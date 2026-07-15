#!/bin/bash
# wifi-manager.sh - Interactive WiFi manager for Slackware Linux (NetworkManager)
#
# Run as root or by members of the 'netdev' group (standard for network control on Slackware).
# Uses the same section header style, echo labeling, and menu flow patterns
# as post-install-global.sh (big star boxes, numbered choices, clear prompts,
# informational SUCCESS/ERROR style messages where appropriate).
#
# Features:
# - Show WiFi devices + current connection state + internet reachability
# - Disconnect (if connected)
# - Scan (full results, no artificial limits)
# - Pick any network from the full scan list
# - Prompt for password only when needed (or always offer to (re)enter)
# - Persist network via NetworkManager (auto-connect survives reboot)
# - Auto-join preference: most-recently-joined network set to autoconnect
# - Fallback: on any connection failure, rejoin the current default WiFi
#
# Prerequisites (normally already present from post-install-global):
#   NetworkManager should be running (started by post-install-global wifi step)
#   nmcli should be available
# Logging is duplicated to screen + ~/logs/wifi-manager-<timestamp>.log (like the global installer).

if [ "$(id -u)" -ne 0 ] && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx netdev; then
    echo "ERROR: This script must be run as root or by a member of the netdev group."
    echo "(Add the user with: usermod -aG netdev username  — then log out and back in.)"
    echo "(You can also run the installer's post-install-user.sh --user <username> to fix this.)"
    exit 1
fi
# Ensure sbin directories are in PATH (iw, ip, dhcpcd live there on Slackware)
export PATH="/usr/sbin:/sbin:$PATH"

# Check that nmcli is available (required)
if ! command -v nmcli >/dev/null 2>&1; then
    echo "ERROR: nmcli (NetworkManager CLI) not found in PATH."
    echo "NetworkManager must be installed and running."
    echo "Run the installer wifi step (./steps/wifi.sh) to set up WiFi."
    exit 1
fi

# Parse command-line flags
VERBOSE=false
case "${1:-}" in
    --verbose|-v) VERBOSE=true ;;
    --help|-h)
        echo "Usage: wifi-manager [--verbose|-v] [--help|-h]"
        echo ""
        echo "  (no flag)  Normal mode: groups scan results by SSID, showing strongest signal."
        echo "  --verbose  Show every raw BSSID line from the scan (old behavior)."
        echo "  --help     Show this help."
        exit 0
        ;;
esac

# Terminal formatting
BOLD='\033[1m'
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
NC='\033[0m'

# Dual logging (everything goes to screen AND the log file)
LOG_DIR="/var/log"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${USER:-root}-wifi-manager-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=================================================="
echo "WiFi Manager started: $(date)"
echo "Log file: $LOG_FILE"
echo "=================================================="


# ------------------------------------------------------------------
# Helpers (style matches the global installer where possible)
# ------------------------------------------------------------------

get_wifi_ifaces() {
    # Return space-separated list of wireless interfaces.
    # Try nmcli first (works even when NM manages the interface),
    # fall back to iw/sysfs.
    local ifaces
    ifaces=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | grep ':wifi$' | cut -d: -f1 | tr '\n' ' ')
    if [ -z "$ifaces" ]; then
        ifaces=$(iw dev 2>/dev/null | awk '$1 == "Interface" { print $2 }' | tr '\n' ' ')
    fi
    if [ -z "$ifaces" ]; then
        ifaces=$(ls /sys/class/net/ 2>/dev/null | grep -E '^(wlan|wlp|wlo)' | tr '\n' ' ')
    fi
    echo "$ifaces"
}

get_active_ssid() {
    # Returns the currently-connected SSID (empty string if none).
    # Works with NetworkManager via nmcli.
    local iface="$1"
    nmcli -t -f GENERAL.CONNECTION device show "$iface" 2>/dev/null | cut -d: -f2
}

get_lan_state() {
    # Returns summary of LAN (ethernet) status.
    # Output: "CONNECTED:iface:conn_name" or "DISCONNECTED" or empty if no LAN devices.
    local lan_ifaces
    lan_ifaces=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | grep ':ethernet$' | cut -d: -f1 | tr '\n' ' ')
    if [ -z "$lan_ifaces" ]; then
        echo ""
        return
    fi
    for liface in $lan_ifaces; do
        local lstate lconn
        lstate=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep "^${liface}:" | cut -d: -f2)
        lconn=$(nmcli -t -f GENERAL.CONNECTION device show "$liface" 2>/dev/null | cut -d: -f2)
        if [ "$lstate" = "connected" ] && [ -n "$lconn" ]; then
            echo "CONNECTED:${liface}:${lconn}"
            return
        fi
    done
    echo "DISCONNECTED"
}

internet_ok() {
    ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1
}

quick_wifi_summary() {
    # Compact summary of WiFi + LAN connection state.
    # Displayed at the top on initial open (and on return to menu after actions).
    # The full "Show WiFi status" menu option (1) remains available for deeper insight.
    local ifaces
    ifaces=$(get_wifi_ifaces)
    if [ -z "$ifaces" ]; then
        echo "No WiFi devices detected."
        return
    fi
    local connected_ssid=""
    for iface in $ifaces; do
        local ssid
        ssid=$(get_active_ssid "$iface")
        if [ -n "$ssid" ]; then
            connected_ssid="$ssid"
            break
        fi
    done

    # Which interface is the active internet route?
    local active_route
    active_route=$(ip route show default 2>/dev/null | awk '{print $NF, $5}' | sort -n | head -1 | awk '{print $2}')

    # WiFi line
    if [ -n "$connected_ssid" ]; then
        local wifi_tag=""
        if [ "$active_route" = "$iface" ]; then wifi_tag=" ${BOLD}${YELLOW}[Internet]${NC}"; fi
        echo -e "WiFi:    ${GREEN}connected${NC}  to ${BOLD}${connected_ssid}${NC}${wifi_tag}"
    else
        echo -e "WiFi:    ${RED}not connected${NC}"
    fi

    # LAN line (only if LAN hardware exists)
    local lan_state lan_line
    lan_state=$(get_lan_state)
    case "$lan_state" in
        CONNECTED:* )
            local lan_iface lan_conn
            lan_iface=$(echo "$lan_state" | cut -d: -f2)
            lan_conn=$(echo "$lan_state" | cut -d: -f3)
            local lan_tag=""
            if [ "$active_route" = "$lan_iface" ]; then lan_tag=" ${BOLD}${YELLOW}[Internet]${NC}"; fi
            echo -e "LAN:     ${GREEN}connected${NC}  on ${lan_iface} (${lan_conn})${lan_tag}"
            ;;
        DISCONNECTED)
            echo -e "LAN:     ${RED}not connected${NC}"
            ;;
        # empty = no LAN hardware, skip entirely
    esac
}

show_status() {
    echo "*****************************************************"
    echo "WIFI STATUS & DEVICES"
    echo "*****************************************************"

    local ifaces
    ifaces=$(get_wifi_ifaces)

    if [ -z "$ifaces" ]; then
        echo "No WiFi devices found (no wireless interfaces detected)."
        echo "Check hardware / kernel modules (e.g. iwlwifi, ath9k, etc.)."
        return
    fi

    echo "Detected WiFi interface(s): $ifaces"
    echo ""

    local any_connected=false

    for iface in $ifaces; do
        echo "----- Device: $iface -----"

        # Basic device info from iw
        iw dev "$iface" info 2>/dev/null | head -5 || echo "  (iw info not available)"

        # NM device state
        local nm_state nm_conn
        nm_state=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep "^${iface}:" | cut -d: -f2)
        nm_conn=$(nmcli -t -f GENERAL.CONNECTION device show "$iface" 2>/dev/null | cut -d: -f2)

        if [ "$nm_state" = "connected" ] && [ -n "$nm_conn" ]; then
            echo -e "  NM state: ${GREEN}connected${NC} to ${BOLD}${nm_conn}${NC}"
            any_connected=true
        else
            echo -e "  NM state: ${RED}${nm_state:-unknown}${NC}"
        fi

        # IP address (if any)
        local ip_info
        ip_info=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / {print $2}' | head -1)
        if [ -n "$ip_info" ]; then
            echo "  IPv4: $ip_info"
        else
            echo "  IPv4: (no address)"
        fi

        echo ""
    done

    # --- LAN / Ethernet section ---
    local lan_ifaces
    lan_ifaces=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | grep ':ethernet$' | cut -d: -f1 | tr '\n' ' ')
    if [ -n "$lan_ifaces" ]; then
        local lan_found=false
        for liface in $lan_ifaces; do
            local lstate lconn lip
            lstate=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep "^${liface}:" | cut -d: -f2)
            lconn=$(nmcli -t -f GENERAL.CONNECTION device show "$liface" 2>/dev/null | cut -d: -f2)
            lip=$(ip -4 addr show dev "$liface" 2>/dev/null | awk '/inet / {print $2}' | head -1)
            echo "----- Device: $liface (ethernet) -----"
            if [ "$lstate" = "connected" ] && [ -n "$lconn" ]; then
                echo -e "  NM state: ${GREEN}connected${NC} to ${BOLD}${lconn}${NC}"
                lan_found=true
            elif [ "$lstate" = "unavailable" ]; then
                echo "  NM state: unavailable (no cable or down)"
            else
                echo -e "  NM state: ${RED}${lstate:-unknown}${NC}"
            fi
            if [ -n "$lip" ]; then
                echo "  IPv4: $lip"
            else
                echo "  IPv4: (no address)"
            fi
            echo ""
        done
    fi

    # Default routes (show which interface carries internet)
    local routes
    routes=$(ip route show default 2>/dev/null)
    if [ -n "$routes" ]; then
        echo "Default routes (lower metric = preferred):"
        # Sort by metric and mark the active one
        local first=true
        while IFS= read -r route; do
            local rdev rmetric
            rdev=$(echo "$route" | awk '{print $5}')
            rmetric=$(echo "$route" | awk '{print $NF}')
            local tag=""
            if $first; then
                tag=" ${YELLOW}← active${NC}"
                first=false
            fi
            printf "  %-8s metric %s%s\n" "$rdev" "$rmetric" "$tag"
        done <<< "$routes"
        echo ""
    fi

    # Internet connectivity check
    local has_internet=false
    if internet_ok; then
        has_internet=true
    fi

    echo "Internet reachability check (ping 8.8.8.8)..."
    if $has_internet; then
        echo -e "  Internet: ${GREEN}YES${NC} (reachable)"
    else
        echo "  Internet: NO (ping failed - may be no default route, captive portal, or upstream issue)"
    fi
}

disconnect_wifi() {
    echo "*****************************************************"
    echo "DISCONNECT WIFI"
    echo "*****************************************************"

    local ifaces
    ifaces=$(get_wifi_ifaces)

    if [ -z "$ifaces" ]; then
        echo "No WiFi devices found."
        return
    fi

    local disconnected_any=false

    for iface in $ifaces; do
        local ssid nm_state
        nm_state=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep "^${iface}:" | cut -d: -f2)
        ssid=$(get_active_ssid "$iface")
        if [ "$nm_state" = "connected" ] && [ -n "$ssid" ]; then
            echo -e "Disconnecting $iface (currently on ${BOLD}${ssid}${NC})..."
            nmcli device disconnect "$iface" 2>/dev/null || true
            echo "  Disconnected $iface."
            disconnected_any=true
        fi
    done

    if $disconnected_any; then
        echo -e "SUCCESS: ${RED}Disconnect${NC} command(s) issued."
        echo "Run 'Show status' to verify."
    else
        echo "No connected WiFi device found to disconnect."
    fi
    echo "*****************************************************"
}

# ------------------------------------------------------------------
# Fallback: rejoin the default (currently-active) WiFi network.
# Called whenever a join_network attempt fails.
# ------------------------------------------------------------------
rejoin_default_wifi() {
    local iface="$1"
    local conn_name="$2"

    if [ -z "$conn_name" ]; then
        echo "  No default WiFi connection name provided — nothing to rejoin."
        return 1
    fi

    echo ""
    echo "-----------------------------------------------------"
    echo -e "Falling back: reconnecting to default WiFi ${BOLD}${conn_name}${NC}..."

    nmcli connection up "$conn_name" 2>/dev/null || {
        echo -e "WARNING: Could not rejoin ${BOLD}${conn_name}${NC}."
        return 1
    }

    # Wait for association
    local reconnected=false
    for i in $(seq 1 20); do
        local state
        state=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep "^${iface}:" | cut -d: -f2)
        if [ "$state" = "connected" ]; then
            reconnected=true
            break
        fi
        sleep 1
    done

    if $reconnected; then
        echo -e "SUCCESS: ${GREEN}Reconnected${NC} to ${BOLD}${conn_name}${NC}."
    else
        echo -e "WARNING: Reconnect to ${BOLD}${conn_name}${NC} timed out."
    fi
    echo "-----------------------------------------------------"
    return 0
}


# Robustly join a network from a scan list (or by SSID).
# Handles password prompt, persistence, and fallback to default WiFi.
join_network() {
    echo "*****************************************************"
    echo "SCAN AND CONNECT TO A WIFI NETWORK"
    echo "*****************************************************"

    local ifaces
    ifaces=$(get_wifi_ifaces)

    if [ -z "$ifaces" ]; then
        echo "ERROR: No WiFi devices found."
        return 1
    fi

    local iface
    iface=$(echo "$ifaces" | awk '{print $1}')

    # Snapshot the currently-active connection BEFORE we do anything,
    # so we can fall back to it on failure.
    local default_conn
    default_conn=$(get_active_ssid "$iface")

    echo "Using interface: $iface"
    echo ""
    echo "Performing fresh scan (shows ALL results)..."
    nmcli device wifi rescan 2>/dev/null || true
    sleep 4

    local scan_output
    scan_output=$(nmcli -t -f SSID,SIGNAL,BSSID,SECURITY device wifi list 2>/dev/null)

    if [ -z "$scan_output" ]; then
        echo "ERROR: No scan results (or scan failed). Check that the interface is up."
        if [ -n "$default_conn" ]; then
            rejoin_default_wifi "$iface" "$default_conn"
        fi
        return 1
    fi

    # Build deduplicated list: group by SSID, keep strongest signal.
    # nmcli -t format: SSID:SIGNAL:BSSID\:xx\:xx...:SECURITY
    # Signal is a percentage (0-100), higher = better.
    local scan_file
    scan_file=$(mktemp /tmp/wifi-scan-XXXXXX) || { echo "ERROR: cannot create temp file"; return 1; }

    if $VERBOSE; then
        # Raw mode: show every BSSID individually
        echo "$scan_output" | sort -t: -k2 -rn > "$scan_file"
    else
        # Grouped mode: keep only the strongest signal for each SSID,
        # skip hidden networks (empty SSID).
        awk -F: '{
            sig = $2 + 0
            ssid = $1
            if (ssid == "") next
            if (!(ssid in seen) || sig > best_sig[ssid]) {
                best_sig[ssid] = sig
                best_line[ssid] = $0
                seen[ssid] = 1
            }
        }
        END {
            for (s in seen) print best_line[s]
        }' <<< "$scan_output" | sort -t: -k2 -rn > "$scan_file"
    fi

    local line_count
    line_count=$(wc -l < "$scan_file")
    if [ "$line_count" -eq 0 ]; then
        rm -f "$scan_file"
        echo "ERROR: No networks found in scan results."
        if [ -n "$default_conn" ]; then
            rejoin_default_wifi "$iface" "$default_conn"
        fi
        return 1
    fi

    echo ""
    if $VERBOSE; then
        echo "Available networks (ALL BSSIDs - verbose mode):"
    else
        echo "Available networks (grouped by name, strongest signal shown):"
    fi
    echo "-----------------------------------------------------"
    local i=1
    local FS=$'\x01'
    while IFS= read -r line; do
        local d_ssid d_signal d_bssid d_security safe_line
        # Replace \: with placeholder to avoid cut splitting on escaped colons
        safe_line=$(echo "$line" | sed 's/\\:/'"$FS"'/g')
        d_ssid=$(echo "$safe_line" | cut -d: -f1 | sed "s/$FS/:/g")
        d_signal=$(echo "$safe_line" | cut -d: -f2)
        d_bssid=$(echo "$safe_line" | cut -d: -f3 | sed "s/$FS/:/g")
        d_security=$(echo "$safe_line" | cut -d: -f4- | sed "s/$FS/:/g")
        printf "%2d. ${BOLD}%-28s${NC} %3s%%  %-17s  %s\n" "$i" "$d_ssid" "$d_signal" "$d_bssid" "$d_security"
        i=$((i+1))
    done < "$scan_file"
    echo "-----------------------------------------------------"

    local choice
    read -p "Enter number of network to join (or X to cancel): " choice
    if [ "$choice" = "x" ] || [ "$choice" = "X" ] || [ "$choice" = "exit" ] || [ "$choice" = "Exit" ] || [ "$choice" = "EXIT" ]; then
        rm -f "$scan_file"
        return 0
    fi
    case "$choice" in
        ''|*[!0-9]*) echo "Invalid choice."; rm -f "$scan_file"; return 0 ;;
    esac
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$line_count" ]; then
        echo "Invalid choice."
        rm -f "$scan_file"
        return 0
    fi

    local selected_line
    selected_line=$(sed -n "${choice}p" "$scan_file")
    rm -f "$scan_file"

    # Parse: SSID:SIGNAL:BSSID:SECURITY (handle \: escapes in BSSID)
    local ssid signal bssid security safe_sel FS2
    FS2=$'\x01'
    safe_sel=$(echo "$selected_line" | sed 's/\\:/'"$FS2"'/g')
    ssid=$(echo "$safe_sel" | cut -d: -f1 | sed "s/$FS2/:/g")
    signal=$(echo "$safe_sel" | cut -d: -f2)
    bssid=$(echo "$safe_sel" | cut -d: -f3 | sed "s/$FS2/:/g")
    security=$(echo "$safe_sel" | cut -d: -f4- | sed "s/$FS2/:/g")

    if [ -z "$ssid" ]; then
        echo "ERROR: Could not parse SSID from selected line."
        if [ -n "$default_conn" ]; then
            rejoin_default_wifi "$iface" "$default_conn"
        fi
        return 1
    fi

    echo ""
    echo -e "Selected: ${BOLD}${ssid}${NC}  (signal: $signal%, security: ${security:-open})"
    echo "BSSID: $bssid"

    # Check if network is already saved in NM
    # Escape regex special chars in SSID for safe grep matching
    local ssid_escaped existing_uuid
    ssid_escaped=$(echo "$ssid" | sed 's/[.[\*^$()+?{|]/\\&/g')
    existing_uuid=$(nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null | grep "^${ssid_escaped}:" | grep ':802-11-wireless$' | head -1 | cut -d: -f2)

    local pass=""
    if [ -z "$existing_uuid" ]; then
        local needs_pass=false
        if echo "$security" | grep -qiE 'WPA|WEP|WPA2|WPA3|SAE|PSK|802.1X'; then
            needs_pass=true
        fi
        if $needs_pass; then
            printf "Enter password for ${BOLD}%s${NC} (input hidden): " "$ssid"; read -s pass; echo
            echo ""
        else
            echo "This network appears to be open (no password required)."
            read -p "Press Enter to continue with open network, or type a password if you know one is needed: " pass
            echo ""
        fi
    else
        echo "  Network already saved (UUID $existing_uuid). Using existing credentials."
    fi

    # ------------------------------------------------------------------
    # Connect via nmcli
    # ------------------------------------------------------------------
    echo -e "Connecting to ${BOLD}${ssid}${NC}..."
    local connect_result
    if [ -n "$pass" ]; then
        connect_result=$(nmcli device wifi connect "$ssid" password "$pass" 2>&1)
    else
        connect_result=$(nmcli device wifi connect "$ssid" 2>&1)
    fi
    local connect_rc=$?

    if [ $connect_rc -ne 0 ]; then
        echo "ERROR: nmcli connect failed:"
        echo "  $connect_result"
        if [ -n "$default_conn" ]; then
            rejoin_default_wifi "$iface" "$default_conn"
        fi
        return 1
    fi

    echo "  $connect_result"

    # Set autoconnect on the new connection
    nmcli connection modify "$ssid" connection.autoconnect yes 2>/dev/null || true

    # Verify connection
    local nm_state
    nm_state=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep "^${iface}:" | cut -d: -f2)
    if [ "$nm_state" != "connected" ]; then
        # Wait a bit for NM to finish
        sleep 3
        nm_state=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep "^${iface}:" | cut -d: -f2)
    fi

    if [ "$nm_state" = "connected" ]; then
        # Internet check
        if internet_ok; then
            echo -e "SUCCESS: ${GREEN}Connected${NC} to ${BOLD}${ssid}${NC} and internet is reachable."
            echo "         Network saved. It will auto-connect on future boots."
        else
            echo -e "SUCCESS: ${GREEN}Connected${NC} to ${BOLD}${ssid}${NC} (saved for auto-connect), but internet check failed."
            echo "         (You may be behind a captive portal or have no upstream route yet.)"
        fi
    else
        echo -e "ERROR: Connection to ${BOLD}${ssid}${NC} did not complete (state: ${nm_state:-unknown})."
        if [ -n "$default_conn" ]; then
            rejoin_default_wifi "$iface" "$default_conn"
        fi
        return 1
    fi

    echo "*****************************************************"
    echo "Tip: Use 'Show status' to verify, or reboot to test auto-connect on boot."
    echo "*****************************************************"
}

list_saved_networks() {
    echo "*****************************************************"
    echo "LIST SAVED NETWORKS (from NetworkManager)"
    echo "*****************************************************"

    local saved
    saved=$(nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null | grep ':802-11-wireless$')

    if [ -z "$saved" ]; then
        echo "No saved WiFi networks."
        echo "*****************************************************"
        return
    fi

    echo "Saved networks:"
    echo "-----------------------------------------------------"

    local nids_file
    nids_file=$(mktemp /tmp/wifi-nids-XXXXXX) || { echo "ERROR: cannot create temp file"; return; }
    local count=0
    while IFS= read -r line; do
        count=$((count + 1))
        local n_name n_uuid
        n_name=$(echo "$line" | cut -d: -f1)
        n_uuid=$(echo "$line" | cut -d: -f2)
        echo "$n_uuid" >> "$nids_file"
        local autoconnect
        autoconnect=$(nmcli -t -f connection.autoconnect connection show "$n_uuid" 2>/dev/null | cut -d: -f2)
        local timestamp
        timestamp=$(nmcli -t -f connection.timestamp connection show "$n_uuid" 2>/dev/null | cut -d: -f2)
        printf "%2d. ${BOLD}%-28s${NC} [%s] autoconnect=%s\n" "$count" "$n_name" "$n_uuid" "${autoconnect:-?}"
    done <<< "$saved"
    echo "-----------------------------------------------------"

    echo "Type 'up' to connect, 'X' to return."
    echo ""

    local choice
    read -p "Enter number to connect (or X to return to menu): " choice
    if [ "$choice" = "x" ] || [ "$choice" = "X" ] || [ "$choice" = "exit" ] || [ "$choice" = "Exit" ] || [ "$choice" = "EXIT" ]; then
        rm -f "$nids_file"
        return 0
    fi
    case "$choice" in
        ''|*[!0-9]*) echo "Invalid choice."; rm -f "$nids_file"; return 0 ;;
    esac
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        echo "Invalid choice."
        rm -f "$nids_file"
        return 0
    fi

    local selected_uuid
    selected_uuid=$(sed -n "${choice}p" "$nids_file")
    rm -f "$nids_file"

    local ifaces iface default_conn
    ifaces=$(get_wifi_ifaces)
    iface=$(echo "$ifaces" | awk '{print $1}')
    default_conn=$(get_active_ssid "$iface")

    echo ""
    echo -e "Connecting to saved network (UUID $selected_uuid)..."

    nmcli connection up "$selected_uuid" 2>&1 || {
        echo "ERROR: Failed to bring up connection."
        if [ -n "$default_conn" ]; then
            rejoin_default_wifi "$iface" "$default_conn"
        fi
        return 1
    }

    # Set it to autoconnect
    nmcli connection modify "$selected_uuid" connection.autoconnect yes 2>/dev/null || true

    # Wait a moment and check
    sleep 3
    local nm_state
    nm_state=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep "^${iface}:" | cut -d: -f2)

    if [ "$nm_state" = "connected" ]; then
        if internet_ok; then
            echo -e "SUCCESS: ${GREEN}Connected${NC} and internet is reachable."
        else
            echo -e "SUCCESS: ${GREEN}Connected${NC}, but internet check failed."
            echo "         (You may be behind a captive portal or have no upstream route yet.)"
        fi
    else
        echo "WARNING: Device state is $nm_state (not 'connected' yet)."
        echo "  NetworkManager may still be connecting. Check 'Show status'."
        if [ -n "$default_conn" ]; then
            # Only fall back if we were previously connected AND now we're fully disconnected
            if [ "$nm_state" = "disconnected" ]; then
                rejoin_default_wifi "$iface" "$default_conn"
            fi
        fi
    fi

    echo "*****************************************************"
}

# ------------------------------------------------------------------
# Main menu (same flow style as post-install-global: numbered choices,
# clear section headers, loop until explicit exit)
# ------------------------------------------------------------------

while true; do
    echo ""
    quick_wifi_summary
    echo "*****************************************************"
    echo "WIFI MANAGER - MAIN MENU"
    echo "*****************************************************"
    echo "1. Show WiFi status (devices + connection + internet)"
    echo "2. Disconnect WiFi (if currently connected)"
    echo "3. Scan and connect to a network"
    echo "4. List saved networks"
    echo "X. Exit"
    echo "*****************************************************"

    read -p "Enter choice [1-4 or X]: " choice

    case "$choice" in
        1)
            show_status
            ;;
        2)
            disconnect_wifi
            ;;
        3)
            join_network
            ;;
        4)
            list_saved_networks
            ;;
        x|X|exit|Exit|EXIT)
            echo ""
            echo "Exiting WiFi Manager."
            echo "Full session log is in: $LOG_FILE"
            exit 0
            ;;
        *)
            echo "Invalid choice. Please enter a number 1-4 or X."
            ;;
    esac
done
