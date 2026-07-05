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
# - Persist network + password in /etc/wpa_supplicant/wpa_supplicant.conf
# - Auto-join preference: most-recently-joined network gets highest priority
#   (so wpa_supplicant will prefer it on boot / when multiple saved networks are visible)
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
# Ensure sbin directories are in PATH (wpa_cli, iw, ip, dhcpcd live there on Slackware)
export PATH="/usr/sbin:/sbin:$PATH"

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
NC='\033[0m'

# Dual logging (everything goes to screen AND the log file)
LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/wifi-manager-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=================================================="
echo "WiFi Manager started: $(date)"
echo "Log file: $LOG_FILE"
echo "=================================================="


# ------------------------------------------------------------------
# Helpers (style matches the global installer where possible)
# ------------------------------------------------------------------

get_wifi_ifaces() {
    # Return space-separated list of wireless interfaces
    iw dev 2>/dev/null | awk '$1 == "Interface" { print $2 }' | tr '\n' ' '
}

quick_wifi_summary() {
    # Compact one-line summary of current WiFi connection state.
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
        ssid=$(wpa_cli -i "$iface" status 2>/dev/null | awk -F= '/^ssid=/ {print $2}' | tr -d '"')
        local state
        state=$(wpa_cli -i "$iface" status 2>/dev/null | awk -F= '/^wpa_state=/ {print $2}')
        if [ "$state" = "COMPLETED" ] && [ -n "$ssid" ]; then
            connected_ssid="$ssid"
            break
        fi
    done
    if [ -n "$connected_ssid" ]; then
        echo -e "Wifi Network ${BOLD}${connected_ssid}${NC} is ${GREEN}Connected${NC}"
    else
        echo "No Wifi Network is currently ${RED}Disconnected${NC}"
    fi
}

show_status() {
    echo "*****************************************************"
    echo "WIFI STATUS & DEVICES"
    echo "*****************************************************"

    local ifaces
    ifaces=$(get_wifi_ifaces)

    if [ -z "$ifaces" ]; then
        echo "No WiFi devices found (no wireless interfaces detected via iw)."
        echo "Check hardware / kernel modules (e.g. iwlwifi, ath9k, etc.)."
        return
    fi

    echo "Detected WiFi interface(s): $ifaces"
    echo ""

    local any_connected=false
    local internet_ok=false

    for iface in $ifaces; do
        echo "----- Device: $iface -----"

        # Basic device info
        iw dev "$iface" info 2>/dev/null | head -5 || echo "  (iw info not available)"

        # Link / association state
        local link_state
        link_state=$(iw dev "$iface" link 2>/dev/null | head -3)
        if echo "$link_state" | grep -q "Connected"; then
            echo -e "  Link: ${GREEN}Connected${NC}"
            any_connected=true
        else
            echo -e "  Link: ${RED}Not connected${NC} (or down)"
        fi

        # wpa_supplicant state + current SSID
        local wpa_state ssid
        wpa_state=$(wpa_cli -i "$iface" status 2>/dev/null | awk -F= '/^wpa_state=/ {print $2}')
        ssid=$(wpa_cli -i "$iface" status 2>/dev/null | awk -F= '/^ssid=/ {print $2}' | tr -d '"')

        echo "  wpa_supplicant state: ${wpa_state:-unknown}"
        if [ -n "$ssid" ]; then
            echo -e "  Current SSID: ${BOLD}${ssid}${NC}"
        else
            echo "  Current SSID: (none)"
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

    # Internet connectivity check (only meaningful if we have a default route + address)
    echo "Internet reachability check (ping 8.8.8.8)..."
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        echo "  Internet: YES (reachable)"
        internet_ok=true
    else
        echo "  Internet: NO (ping failed - may be no default route, captive portal, or upstream issue)"
    fi

    echo ""
    if $any_connected; then
        echo "At least one WiFi device is associated."
    else
        echo "No WiFi device is currently associated."
    fi

    if $internet_ok; then
        echo "You appear to have working internet."
    fi
    echo "*****************************************************"
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
        local ssid
        ssid=$(wpa_cli -i "$iface" status 2>/dev/null | awk -F= '/^ssid=/ {print $2}' | tr -d '"')
        local state
        state=$(wpa_cli -i "$iface" status 2>/dev/null | awk -F= '/^wpa_state=/ {print $2}')

        if [ "$state" = "COMPLETED" ] || [ -n "$ssid" ]; then
            echo -e "Disconnecting $iface (currently on ${BOLD}${ssid}${NC})..."
            wpa_cli -i "$iface" disconnect 2>/dev/null || true
            dhcpcd -k "$iface" 2>/dev/null || true
            echo "  Sent disconnect to $iface."
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


# Robustly join a network from a scan list (or by SSID).
# Handles password prompt, persistence, and most-recently-joined priority.
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

    echo "Using interface: $iface"
    echo ""
    echo "Performing fresh scan (shows ALL results)..."
    wpa_cli -i "$iface" scan >/dev/null 2>&1 || true
    sleep 3

    local scan_output
    scan_output=$(wpa_cli -i "$iface" scan_results 2>/dev/null)

    if [ -z "$scan_output" ] || [ "$(echo "$scan_output" | wc -l)" -le 1 ]; then
        echo "ERROR: No scan results (or scan failed). Check that the interface is up."
        return 1
    fi

    # Build list of scan lines in a temp file (POSIX, no bash arrays)
    local scan_file
    scan_file=$(mktemp /tmp/wifi-scan-XXXXXX) || { echo "ERROR: cannot create temp file"; return 1; }
    echo "$scan_output" | tail -n +2 | sort -t$'\t' -k3 -rn > "$scan_file"

    local line_count
    line_count=$(wc -l < "$scan_file")
    if [ "$line_count" -eq 0 ]; then
        rm -f "$scan_file"
        echo "ERROR: No networks found in scan results."
        return 1
    fi
    # Decide: grouped-by-SSID (default) or raw BSSID list (--verbose)
    local active_file active_count
    if $VERBOSE; then
        # Reformat raw lines: SSID first for display
        local scan_file_fmt
        scan_file_fmt=$(mktemp /tmp/wifi-scan-fmt-XXXXXX) || { rm -f "$scan_file"; echo "ERROR: cannot create temp file"; return 1; }
        awk '{
            bssid=$1; signal=$3; flags=$4
            ssid=$5; for(i=6;i<=NF;i++) ssid=ssid" "$i
            printf "%s\t%s dBm\t%s\t%s\n", ssid, signal, bssid, flags
        }' "$scan_file" > "$scan_file_fmt"
        rm -f "$scan_file"
        active_file="$scan_file_fmt"
        active_count="$line_count"
    else
        # Group by SSID: keep only the strongest-signal entry for each SSID.
        # This collapses multiple BSSIDs advertising the same SSID (mesh APs,
        # dual-band) into a single entry, while still showing truly distinct
        # networks under different names.
        local scan_file_dedup
        scan_file_dedup=$(mktemp /tmp/wifi-scan-dedup-XXXXXX) || { rm -f "$scan_file"; echo "ERROR: cannot create temp file"; return 1; }
        awk '{
            sig = $3 + 0
            bssid = $1; signal = $3; flags = $4
            ssid = $5
            for (i = 6; i <= NF; i++) ssid = ssid " " $i
            if (!(ssid in seen) || sig > best_sig[ssid]) {
                best_sig[ssid] = sig
                best_line[ssid] = sprintf("%s\t%s dBm\t%s\t%s", ssid, signal, bssid, flags)
                seen[ssid] = 1
            }
        }
        END {
            for (s in seen) print best_line[s]
        }' "$scan_file" | sort -t$'\t' -k2 -rn > "$scan_file_dedup"
        rm -f "$scan_file"

        local dedup_count
        dedup_count=$(wc -l < "$scan_file_dedup")
        if [ "$dedup_count" -eq 0 ]; then
            rm -f "$scan_file_dedup"
            echo "ERROR: No networks found after deduplication."
            return 1
        fi
        active_file="$scan_file_dedup"
        active_count="$dedup_count"
    fi

    echo ""
    if $VERBOSE; then
        echo "Available networks (ALL BSSIDs - verbose mode):"
    else
        echo "Available networks (grouped by name, strongest signal shown):"
    fi
    echo "-----------------------------------------------------"
    local i=1
    while IFS= read -r line; do
        d_ssid=$(echo "$line" | cut -f1)
        d_signal=$(echo "$line" | cut -f2)
        d_bssid=$(echo "$line" | cut -f3)
        d_flags=$(echo "$line" | cut -f4)
        printf "%2d. ${BOLD}%-28s${NC} %8s  %-17s  %s\n" "$i" "$d_ssid" "$d_signal" "$d_bssid" "$d_flags"
        i=$((i+1))
    done < "$active_file"
    echo "-----------------------------------------------------"

    local choice
    read -p "Enter number of network to join (or X to cancel): " choice
    if [ "$choice" = "x" ] || [ "$choice" = "X" ] || [ "$choice" = "exit" ] || [ "$choice" = "Exit" ] || [ "$choice" = "EXIT" ]; then
        rm -f "$active_file"
        return 0
    fi
    case "$choice" in
        ''|*[!0-9]*) echo "Invalid choice."; rm -f "$active_file"; return 0 ;;
    esac
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$active_count" ]; then
        echo "Invalid choice."
        rm -f "$active_file"
        return 0
    fi

    local selected_line
    selected_line=$(sed -n "${choice}p" "$active_file")
    rm -f "$active_file"

    # Parse the reformatted line.
    # Format: SSID<TAB>SIGNAL dBm<TAB>FLAGS<TAB>BSSID
    local bssid signal flags ssid
    ssid=$(echo "$selected_line" | cut -f1)
    signal=$(echo "$selected_line" | cut -f2 | sed 's/ dBm//')
    bssid=$(echo "$selected_line" | cut -f3)
    flags=$(echo "$selected_line" | cut -f4)
    # wpa_cli scan_results escapes non-ASCII as \\xHH; decode to raw bytes
    ssid=$(printf '%b' "$ssid")
    # Hex-encode SSID for robust wpa_cli set_network (passes raw bytes correctly)
    ssid_hex=$(printf '%s' "$ssid" | xxd -p | tr -d '\n')

    if [ -z "$ssid" ]; then
        echo "ERROR: Could not parse SSID from selected line."
        return 1
    fi

    echo ""
    echo -e "Selected: ${BOLD}${ssid}${NC}  (signal: $signal dBm, flags: $flags)"
    echo "BSSID: $bssid"

    # Find if this SSID is already saved (use get_network to get raw SSID
    # bytes, avoiding \\x escape mismatch from list_networks output).
    local existing_id=""
    local wpacli_tmp
    wpacli_tmp=$(mktemp /tmp/wifi-wpacli-XXXXXX) || { echo "ERROR: cannot create temp file"; return 1; }
    wpa_cli -i "$iface" list_networks 2>/dev/null | tail -n +2 > "$wpacli_tmp" 2>/dev/null || true
    while read -r line; do
        nid=$(echo "$line" | cut -f1)
        # wpa_cli get_network returns raw SSID bytes, avoiding escape mismatch
        nssid=$(wpa_cli -i "$iface" get_network "$nid" ssid 2>/dev/null | head -1)
        # get_network returns SSID as quoted ASCII (possibly with \\x escapes)
        # or bare hex for non-ASCII. Normalize to hex for byte-accurate comparison.
        nssid=$(echo "$nssid" | tr -d '"')
        if echo "$nssid" | grep -q '[^0-9a-fA-F]'; then
            # Not pure hex — decode \\x escapes then hex-encode
            nssid=$(printf '%b' "$nssid" | xxd -p | tr -d '\n')
        fi
        if [ "$nssid" = "$ssid_hex" ]; then
            existing_id="$nid"
            break
        fi
    done < "$wpacli_tmp"
    rm -f "$wpacli_tmp"

    # Only prompt for password if the network is NOT already saved
    local pass=""
    if [ -z "$existing_id" ]; then
        local needs_pass=false
        if echo "$flags" | grep -qiE 'WPA|WEP|SAE|PSK'; then
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
    fi

    # ------------------------------------------------------------------
    # Add / update the network via wpa_cli
    # ------------------------------------------------------------------
    echo -e "Configuring network ${BOLD}${ssid}${NC}..."

    local net_id
    if [ -n "$existing_id" ]; then
        echo "  Network already saved (id $existing_id). Using existing credentials."
        net_id="$existing_id"
    else
        echo "  Adding new network..."
        net_id=$(wpa_cli -i "$iface" add_network 2>/dev/null | tail -1)
        if [ -z "$net_id" ] || [ "$net_id" = "FAIL" ]; then
            echo "ERROR: Failed to add network via wpa_cli."
            return 1
        fi
        # Set SSID as hex (no quotes) — robust for non-ASCII characters
        wpa_cli -i "$iface" set_network "$net_id" ssid "$ssid_hex" >/dev/null
        if [ -n "$pass" ]; then
            wpa_cli -i "$iface" set_network "$net_id" psk "\"$pass\"" >/dev/null
        else
            wpa_cli -i "$iface" set_network "$net_id" key_mgmt NONE >/dev/null
        fi
        wpa_cli -i "$iface" set_network "$net_id" scan_ssid 1 >/dev/null 2>&1 || true   # helps with some hidden/edge cases
    fi

    # ------------------------------------------------------------------
    # Set highest priority for "most-recently-joined" auto-connect preference
    # ------------------------------------------------------------------
    local max_prio=0
    for nid in $(wpa_cli -i "$iface" list_networks 2>/dev/null | tail -n +2 | cut -f1); do
        local p
        p=$(wpa_cli -i "$iface" get_network "$nid" priority 2>/dev/null || echo 0)
        if [ "$p" -gt "$max_prio" ]; then
            max_prio=$p
        fi
    done
    local new_prio=$((max_prio + 10))
    wpa_cli -i "$iface" set_network "$net_id" priority "$new_prio" >/dev/null

    # Enable and select it now
    wpa_cli -i "$iface" enable_network "$net_id" >/dev/null
    wpa_cli -i "$iface" select_network "$net_id" >/dev/null

    echo "  Selected network id $net_id with priority $new_prio (most recent = highest priority)."

    # ------------------------------------------------------------------
    # Wait for association + IP (modeled after the original installer logic)
    # ------------------------------------------------------------------
    echo "Waiting for association (up to 30s)..."
    local connected=false
    for i in $(seq 1 30); do
        local state
        state=$(wpa_cli -i "$iface" status 2>/dev/null | awk -F= '/^wpa_state=/ {print $2}')
        if [ "$state" = "COMPLETED" ]; then
            connected=true
            break
        fi
        sleep 1
    done

    if ! $connected; then
        echo -e "ERROR: Failed to associate with ${BOLD}${ssid}${NC} (timed out)."
        echo "Check password, signal strength, or try scanning again."
        return 1
    fi

    echo "  Association successful (COMPLETED)."

    # Wait for DHCP / IP
    echo "Waiting for IP address (up to 30s)..."
    local has_ip=false
    for i in $(seq 1 30); do
        if ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'inet '; then
            has_ip=true
            break
        fi
        sleep 1
    done

    if $has_ip; then
        echo "  IP address obtained."
    else
        echo "  WARNING: No IP address yet (dhcpcd may still be working, or static config needed)."
    fi

    # Persist the config (so it survives reboot)
    wpa_cli -i "$iface" save_config >/dev/null 2>&1 || true

    # Final quick internet check
    echo ""
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        echo -e "SUCCESS: ${GREEN}Connected${NC} to ${BOLD}${ssid}${NC} and internet is reachable."
        echo "         Network saved. It will be preferred for future auto-connect (highest priority)."
    else
        echo -e "SUCCESS: ${GREEN}Connected${NC} to ${BOLD}${ssid}${NC} (saved for auto-connect), but internet check failed."
        echo "         (You may be behind a captive portal or have no upstream route yet.)"
    fi

    echo "*****************************************************"
    echo "Tip: Use 'Show status' to verify, or reboot to test auto-connect on boot."
    echo "*****************************************************"
}

list_saved_networks() {
    echo "*****************************************************"
    echo "LIST SAVED NETWORKS (from wpa_supplicant)"
    echo "*****************************************************"

    local ifaces
    ifaces=$(get_wifi_ifaces)
    local iface
    iface=$(echo "$ifaces" | awk '{print $1}')

    if [ -z "$iface" ]; then
        echo "No WiFi interface available to query."
        return
    fi

    local list_tmp
    list_tmp=$(mktemp /tmp/wifi-list-XXXXXX) || { echo "ERROR: cannot create temp file"; return; }
    wpa_cli -i "$iface" list_networks 2>/dev/null > "$list_tmp"
    head -1 "$list_tmp"   # show header line

    # Write body to a temp file so we can read in a non-subshell while loop
    local body_tmp
    body_tmp=$(mktemp /tmp/wifi-body-XXXXXX) || { rm -f "$list_tmp"; echo "ERROR: cannot create temp file"; return; }
    tail -n +2 "$list_tmp" > "$body_tmp"
    rm -f "$list_tmp"

    # Store nids for lookup by user choice number (one per line, same order)
    local nids_file
    nids_file=$(mktemp /tmp/wifi-nids-XXXXXX) || { rm -f "$body_tmp"; echo "ERROR: cannot create temp file"; return; }

    echo "Saved networks:"
    echo "-----------------------------------------------------"
    local count=0
    while read -r line; do
        count=$((count + 1))
        nid=$(echo "$line" | cut -f1)
        echo "$nid" >> "$nids_file"
        nssid_raw=$(wpa_cli -i "$iface" get_network "$nid" ssid 2>/dev/null | head -1)
        nssid=$(echo "$nssid_raw" | tr -d '"')
        if echo "$nssid" | grep -q '[^0-9a-fA-F]'; then
            nssid=$(printf '%b' "$nssid")
        else
            nssid=$(echo "$nssid" | xxd -r -p)
        fi
        rest=$(echo "$line" | cut -f3-)
        printf "%2d. ${BOLD}%-28s${NC} [id %s] %s\n" "$count" "$nssid" "$nid" "$rest"
    done < "$body_tmp"
    echo "-----------------------------------------------------"

    if [ "$count" -eq 0 ]; then
        echo "No saved networks."
        rm -f "$body_tmp" "$nids_file"
        echo "*****************************************************"
        return
    fi

    echo "Higher priority number = preferred for auto-connect on boot."
    echo ""

    local choice
    read -p "Enter number to connect (or X to return to menu): " choice
    if [ "$choice" = "x" ] || [ "$choice" = "X" ] || [ "$choice" = "exit" ] || [ "$choice" = "Exit" ] || [ "$choice" = "EXIT" ]; then
        rm -f "$body_tmp" "$nids_file"
        return 0
    fi
    case "$choice" in
        ''|*[!0-9]*) echo "Invalid choice."; rm -f "$body_tmp" "$nids_file"; return 0 ;;
    esac
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        echo "Invalid choice."
        rm -f "$body_tmp" "$nids_file"
        return 0
    fi

    local selected_nid selected_ssid
    selected_nid=$(sed -n "${choice}p" "$nids_file")
    selected_ssid_raw=$(wpa_cli -i "$iface" get_network "$selected_nid" ssid 2>/dev/null | head -1)
    selected_ssid=$(echo "$selected_ssid_raw" | tr -d '"')
    if echo "$selected_ssid" | grep -q '[^0-9a-fA-F]'; then
        selected_ssid=$(printf '%b' "$selected_ssid")
    else
        selected_ssid=$(echo "$selected_ssid" | xxd -r -p)
    fi
    rm -f "$body_tmp" "$nids_file"

    echo ""
    echo -e "Connecting to saved network ${BOLD}${selected_ssid}${NC} (id $selected_nid)..."

    # Set highest priority for most-recently-connected preference
    local max_prio=0
    for nid in $(wpa_cli -i "$iface" list_networks 2>/dev/null | tail -n +2 | cut -f1); do
        local p
        p=$(wpa_cli -i "$iface" get_network "$nid" priority 2>/dev/null || echo 0)
        if [ "$p" -gt "$max_prio" ]; then
            max_prio=$p
        fi
    done
    local new_prio=$((max_prio + 10))
    wpa_cli -i "$iface" set_network "$selected_nid" priority "$new_prio" >/dev/null

    wpa_cli -i "$iface" enable_network "$selected_nid" >/dev/null
    wpa_cli -i "$iface" select_network "$selected_nid" >/dev/null
    echo "  Selected network id $selected_nid with priority $new_prio."

    # Wait for association
    echo "Waiting for association (up to 30s)..."
    local connected=false
    for i in $(seq 1 30); do
        local state
        state=$(wpa_cli -i "$iface" status 2>/dev/null | awk -F= '/^wpa_state=/ {print $2}')
        if [ "$state" = "COMPLETED" ]; then
            connected=true
            break
        fi
        sleep 1
    done

    if ! $connected; then
        echo "ERROR: Failed to associate (timed out)."
        echo "  The saved credentials may be wrong, or the network is out of range."
        return 1
    fi

    echo "  Association successful (COMPLETED)."

    # Wait for DHCP / IP
    echo "Waiting for IP address (up to 30s)..."
    local has_ip=false
    for i in $(seq 1 30); do
        if ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'inet '; then
            has_ip=true
            break
        fi
        sleep 1
    done

    if $has_ip; then
        echo "  IP address obtained."
    else
        echo "  WARNING: No IP address yet (dhcpcd may still be working)."
    fi

    wpa_cli -i "$iface" save_config >/dev/null 2>&1 || true

    echo ""
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        echo -e "SUCCESS: ${GREEN}Connected${NC} and internet is reachable."
    else
        echo -e "SUCCESS: ${GREEN}Connected${NC}, but internet check failed."
        echo "         (You may be behind a captive portal or have no upstream route yet.)"
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
