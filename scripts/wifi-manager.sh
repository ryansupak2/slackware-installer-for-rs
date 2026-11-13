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
# - Prompt for password only when needed, or deliberately re-enter it
# - Retry a rejected password instead of saving it: a profile that exists only
#   because of a failed attempt is removed, and an already-saved profile can be
#   re-keyed in place, so one typo cannot make a network permanently unjoinable
# - List saved networks, delete one, and prioritize them: rank 1 is the network
#   tried first on boot, rank 2 is the fallback after it, and so on
#   (stored as connection.autoconnect-priority, so it survives reboots)
# - Persist network via NetworkManager (auto-connect survives reboot)
# - Auto-join preference: most-recently-joined network set to autoconnect
# - Fallback: on any connection failure, rejoin the current default WiFi
#
# Prerequisites (normally already present from post-install-global):
#   NetworkManager should be running (started by post-install-global wifi step)
#   nmcli should be available
# Logging is duplicated to screen + /var/log/wifimanager-<timestamp>.log (like the global installer).

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
STATUS_ONLY=false
case "${1:-}" in
    --verbose|-v) VERBOSE=true ;;
    --status|-s)  STATUS_ONLY=true ;;
    --help|-h)
        echo "Usage: wifi-manager [--status|-s] [--verbose|-v] [--help|-h]"
        echo ""
        echo "  (no flag)  Interactive menu (what the 'wifi' alias runs)."
        echo "  --status   Print what WiFi is connected to right now, then exit."
        echo "  --verbose  Show every raw BSSID line from the scan (old behavior)."
        echo "  --help     Show this help."
        exit 0
        ;;
esac

# Terminal formatting (colors only when stdout is a TTY, so logs stay clean)
BOLD=''
GREEN=''
RED=''
YELLOW=''
NC=''
if [ -t 1 ]; then
    BOLD=$(printf '\033[1m')
    GREEN=$(printf '\033[32m')
    RED=$(printf '\033[31m')
    YELLOW=$(printf '\033[33m')
    NC=$(printf '\033[0m')
fi

# Dual logging (everything goes to screen AND the log file)
# --status is a snapshot: it keeps the log (a record of what the session
# connected to) but skips the banner so the block reads cleanly under the
# fastfetch splash in the first terminal.
LOG_DIR="/var/log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/${USER:-root}-wifi-manager-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

if ! $STATUS_ONLY; then
    echo "=================================================="
    echo "WiFi Manager started: $(date)"
    echo "Log file: $LOG_FILE"
    echo "=================================================="
fi


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

connection_details() {
    # One compact block describing the CURRENT connection: device, network,
    # BSSID, signal, address and gateway.
    # Used by --status, i.e. the summary the session's first terminal shows
    # right after the fastfetch splash (see dotfiles/shell/bashrc).
    # Deliberately no ping here: routing already answers "is there internet?"
    # via the [Internet] tag in quick_wifi_summary, and a startup screen must
    # not block for seconds when the uplink is down.
    local ifaces iface ssid ip_info gw sig bssid
    ifaces=$(get_wifi_ifaces)

    for iface in $ifaces; do
        ssid=$(get_active_ssid "$iface")
        [ -z "$ssid" ] && continue

        ip_info=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / {print $2; exit}')
        gw=$(ip route show default dev "$iface" 2>/dev/null | awk '/default/ {print $3; exit}')
        sig=$(iw dev "$iface" link 2>/dev/null | awk '/signal:/ {print $2" "$3; exit}')
        bssid=$(iw dev "$iface" link 2>/dev/null | awk '/Connected to/ {print $3; exit}')

        echo "Device:  $iface"
        echo -e "Network: ${BOLD}${ssid}${NC}"
        [ -n "$bssid" ] && echo "BSSID:   $bssid"
        [ -n "$sig" ]   && echo "Signal:  $sig"
        echo "Address: ${ip_info:-(no address)}"
        echo "Gateway: ${gw:-(none)}"
    done
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


# ------------------------------------------------------------------
# Helpers shared by connect / list / delete
#
# These exist because of one specific failure mode: a wrong password still
# leaves a profile behind in NetworkManager. The bad secret is then "saved",
# autoconnect keeps retrying it, and the network becomes unjoinable until the
# profile is found and removed by hand. Everything below works on the saved
# profile explicitly, so a mistyped password can be corrected instead.
# ------------------------------------------------------------------

device_state() {
    # NetworkManager's state for one device (connected, disconnected, ...).
    local iface="$1"
    nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep "^${iface}:" | cut -d: -f2
}

nm_field() {
    # `nmcli -t -f FIELD connection show <uuid>` prints "FIELD:value":
    # drop the field name and undo terse-mode "\:" escaping.
    sed -e 's/^[^:]*://' -e 's/\\:/:/g'
}

find_connection_uuid() {
    # UUID of the saved WiFi profile for SSID $1 ("" when none is saved).
    local ssid="$1" escaped
    escaped=$(printf '%s' "$ssid" | sed 's/[][\.\*^$()+?{|]/\\&/g')
    nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null \
        | grep "^${escaped}:" | grep ':802-11-wireless$' \
        | head -1 | cut -d: -f2
}

active_wifi_uuid() {
    # UUID of the WiFi profile that is active right now ("" when none).
    nmcli -t -f UUID,TYPE connection show --active 2>/dev/null \
        | grep ':802-11-wireless$' | cut -d: -f1 | head -1
}

# ------------------------------------------------------------------
# Auto-connect priority: the ORDER saved networks are tried in
#
# "1 = first" is not a NetworkManager concept. What it has is
# connection.autoconnect-priority, where the HIGHEST number is tried first and
# ties are broken by the most recent activation. So rank 1 is stored as the
# highest number and every following rank as a lower one, spaced by 10 so a
# single re-rank never collides with the rest.
# ------------------------------------------------------------------

connection_priority() {
    # autoconnect-priority of profile $1 (0 = NetworkManager's default).
    local v
    v=$(nmcli -t -f connection.autoconnect-priority connection show "$1" 2>/dev/null | nm_field)
    case "$v" in
        ''|*[!0-9-]*) echo 0 ;;
        *)            echo "$v" ;;
    esac
}

saved_wifi_order() {
    # Every saved WiFi profile in the order NetworkManager will try them, as
    #   "<priority>|<autoconnect>|<timestamp>|<uuid>|<name>"
    # Highest priority first, ties broken by the most recent activation —
    # NetworkManager's own ranking, so what is printed is what happens.
    local line name uuid auto prio ts
    nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null \
    | grep ':802-11-wireless$' \
    | while IFS= read -r line; do
        name=$(printf '%s' "$line" | cut -d: -f1)
        uuid=$(printf '%s' "$line" | cut -d: -f2)
        auto=$(nmcli -t -f connection.autoconnect connection show "$uuid" 2>/dev/null | nm_field)
        prio=$(connection_priority "$uuid")
        ts=$(nmcli -t -f connection.timestamp connection show "$uuid" 2>/dev/null | nm_field)
        case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
        printf '%s|%s|%s|%s|%s\n' "$prio" "${auto:-yes}" "$ts" "$uuid" "$name"
    done \
    | sort -t'|' -k1,1nr -k3,3nr
}

apply_autoconnect_order() {
    # $@ = profile UUIDs, rank 1 first. Rank 1 gets the highest priority, so
    # every ranked profile outranks the untouched default (0) and there is
    # room between the ranks. Non-zero return if any write failed.
    local uuids=("$@") n i rc=0
    n=${#uuids[@]}
    for i in "${!uuids[@]}"; do
        nmcli connection modify "${uuids[$i]}" \
            connection.autoconnect-priority "$(( (n - i) * 10 ))" >/dev/null 2>&1 || rc=1
    done
    return $rc
}
show_priority_list() {
    # $1 = file that receives the ordered UUIDs (one per line). Prints rank,
    # name, stored priority and any reason a profile is skipped at boot.
    local file="$1" rank=0 prio auto ts uuid name active marker
    : > "$file"
    active=$(active_wifi_uuid)
    while IFS='|' read -r prio auto ts uuid name; do
        [ -n "$uuid" ] || continue
        rank=$((rank + 1))
        printf '%s\n' "$uuid" >> "$file"
        marker=""
        [ "$uuid" = "$active" ] && marker=" ${YELLOW}${BOLD}(connected now)${NC}"
        [ "$auto" = "no" ] && marker="$marker ${RED}(autoconnect=no - skipped at boot)${NC}"
        printf "%2d. ${BOLD}%-28s${NC} priority=%-4s%b\n" "$rank" "$name" "$prio" "$marker"
    done < <(saved_wifi_order)
}

reorder_uuid_file() {
    # $1 = file of UUIDs, $2 = current rank, $3 = new rank. Ranks are 1-based;
    # only the moved entry changes place, everything else keeps its order.
    local file="$1" from="$2" to="$3" moved i
    local -a arr=() rest=() out=()
    mapfile -t arr < "$file"
    moved="${arr[$((from - 1))]}"
    for i in "${!arr[@]}"; do
        [ "$i" -eq "$((from - 1))" ] && continue
        rest+=("${arr[$i]}")
    done
    for i in "${!rest[@]}"; do
        [ "$i" -eq "$((to - 1))" ] && out+=("$moved")
        out+=("${rest[$i]}")
    done
    # Appending to the end of the list has no "before" element above.
    [ "$to" -gt "${#rest[@]}" ] && out+=("$moved")
    printf '%s\n' "${out[@]}" > "$file"
}

apply_last_used_order() {
    # $1 = file to receive the UUIDs ranked by most recent activation
    # (1 = joined most recently). Ties keep their current priority order.
    local file="$1" prio auto ts uuid name
    : > "$file"
    saved_wifi_order | sort -s -t'|' -k3,3nr -k1,1nr \
    | while IFS='|' read -r prio auto ts uuid name; do
        [ -n "$uuid" ] && printf '%s\n' "$uuid"
    done >> "$file"
}


connection_key_mgmt() {
    # Security stored in profile $1: wpa-psk, sae, ieee8021x... ("" = open).
    nmcli -t -f 802-11-wireless-security.key-mgmt connection show "$1" 2>/dev/null | nm_field
}

connection_wep_key_type() {
    # "unknown"/"" for anything that is not WEP.
    nmcli -t -f 802-11-wireless-security.wep-key-type connection show "$1" 2>/dev/null | nm_field
}

connection_needs_password() {
    # "true" when profile $1 holds a passphrase we know how to rewrite.
    local km wep
    km=$(connection_key_mgmt "$1")
    case "$km" in
        wpa-psk|sae) echo true; return ;;
    esac
    wep=$(connection_wep_key_type "$1")
    if [ -n "$wep" ] && [ "$wep" != "unknown" ]; then
        echo true
    else
        echo false
    fi
}

set_connection_password() {
    # Store $2 as the passphrase of profile $1, so the *saved* secret is
    # corrected in place instead of a second profile appearing next to it.
    local uuid="$1" pass="$2" km wep
    km=$(connection_key_mgmt "$uuid")
    case "$km" in
        wpa-psk|sae)
            nmcli connection modify "$uuid" wifi-sec.psk "$pass" 2>&1 ;;
        ''|none)
            wep=$(connection_wep_key_type "$uuid")
            if [ -n "$wep" ] && [ "$wep" != "unknown" ]; then
                # WEP profile: the key lives in wep-key0, key management stays 'none'.
                nmcli connection modify "$uuid" wifi-sec.wep-key0 "$pass" 2>&1
            else
                # Really open: key management has to be set too, otherwise
                # nmcli rejects a psk on its own.
                nmcli connection modify "$uuid" wifi-sec.key-mgmt wpa-psk \
                    wifi-sec.psk "$pass" 2>&1
            fi ;;
        *)
            echo "  (Saved security is '$km'; its secret lives in the 802.1X settings and is left alone.)" >&2
            return 1 ;;
    esac
}

PROMPTED_PASSWORD=""
prompt_password() {
    # Ask for a passphrase with echo off. The answer lands in $PROMPTED_PASSWORD
    # (a global, so an empty answer and leading/trailing spaces survive).
    local ssid="$1" pass=""
    printf "Enter password for ${BOLD}%s${NC} (input hidden, empty = no password): " "$ssid"
    read -rs pass || true
    echo ""
    PROMPTED_PASSWORD="$pass"
}

confirm_yes() {
    # $1 = prompt, $2 = default answer ('n' unless given). Only an explicit
    # answer counts, so a stray Enter can never delete or overwrite anything.
    local prompt="$1" def="${2:-n}" reply
    if [ "$def" = "y" ]; then
        read -r -p "$prompt [Y/n]: " reply
        case "$reply" in
            n|N|no|No|NO) return 1 ;;
            *)            return 0 ;;
        esac
    fi
    read -r -p "$prompt [y/N]: " reply
    case "$reply" in
        y|Y|yes|Yes|YES) return 0 ;;
        *)               return 1 ;;
    esac
}

wifi_connect_try() {
    # One complete connection attempt.
    #   $1 interface, $2 SSID, $3 passphrase to store ("" = keep the stored one),
    #   $4 UUID of the profile to use ("" = let nmcli create one).
    # Returns 0 only when this device is really activated on that profile.
    local iface="$1" ssid="$2" pass="$3" uuid="$4"
    local out rc i target_name=""

    if [ -n "$uuid" ] && [ -n "$pass" ]; then
        set_connection_password "$uuid" "$pass" >/dev/null || true
    fi

    if [ -n "$uuid" ]; then
        out=$(nmcli connection up "$uuid" 2>&1); rc=$?
    elif [ -n "$pass" ]; then
        out=$(nmcli device wifi connect "$ssid" password "$pass" 2>&1); rc=$?
    else
        out=$(nmcli device wifi connect "$ssid" 2>&1); rc=$?
    fi
    [ -n "$out" ] && echo "  $out"

    # nmcli can exit 0 while NetworkManager is still activating (or while the
    # device sits on some other profile), so trust the device state instead.
    if [ -n "$uuid" ]; then
        target_name=$(nmcli -t -f connection.id connection show "$uuid" 2>/dev/null | nm_field)
    fi
    # Profiles created by `nmcli device wifi connect` are named after the SSID.
    [ -z "$target_name" ] && target_name="$ssid"

    # An explicit nmcli error is already a verdict: only a short grace period
    # is left for a late activation, instead of the full wait for success.
    local wait=20
    [ "$rc" -ne 0 ] && wait=5

    for i in $(seq 1 "$wait"); do
        if [ "$(device_state "$iface")" = "connected" ] \
           && [ "$(get_active_ssid "$iface")" = "$target_name" ]; then
            return 0
        fi
        sleep 1
    done

    echo "  Not connected (device: $(device_state "$iface"), active profile: $(get_active_ssid "$iface"))."
    return 1
}

wifi_connect_with_retry() {
    # Connect and, if the passphrase is rejected, let the user correct it
    # instead of leaving the bad secret saved. Any profile that only exists
    # because of a failed attempt is removed again.
    #   $1 interface, $2 SSID, $3 UUID to use ("" = create one),
    #   $4 passphrase to store ("" = use the stored one),
    #   $5 whether a passphrase is involved (true/false),
    #   $6 UUID that already existed before we started ("" = none)
    local iface="$1" ssid="$2" uuid="$3" pass="$4" needs_pass="$5" preexisting="$6"
    local attempt=0 max_attempts=3 current_uuid final_uuid

    while [ "$attempt" -lt "$max_attempts" ]; do
        attempt=$((attempt + 1))
        echo ""
        echo -e "Connecting to ${BOLD}${ssid}${NC} (attempt $attempt/$max_attempts)..."
        if wifi_connect_try "$iface" "$ssid" "$pass" "$uuid"; then
            # This is now the network to prefer on boot.
            final_uuid=$(find_connection_uuid "$ssid")
            [ -z "$final_uuid" ] && final_uuid="$uuid"
            if [ -n "$final_uuid" ]; then
                nmcli connection modify "$final_uuid" connection.autoconnect yes >/dev/null 2>&1
            fi
            return 0
        fi

        # A failed activation still leaves the profile holding the secret we
        # just tried. If this attempt is the reason the profile exists, remove
        # it: keeping it is what made one typo permanent, because autoconnect
        # then retries the bad secret forever and nothing could overwrite it.
        current_uuid=$(find_connection_uuid "$ssid")
        if [ -z "$preexisting" ] && [ -n "$current_uuid" ]; then
            if nmcli connection delete "$current_uuid" >/dev/null 2>&1; then
                echo "  Removed the profile this attempt created (the wrong password is not kept)."
            fi
            uuid=""
        else
            uuid="$current_uuid"
        fi

        [ "$attempt" -ge "$max_attempts" ] && break

        if [ "$needs_pass" = "true" ]; then
            echo ""
            echo "  That password was not accepted (or the network refused the connection)."
            if confirm_yes "  Try again with a different password?" y; then
                prompt_password "$ssid"
                pass="$PROMPTED_PASSWORD"
            else
                break
            fi
        else
            # Open network: repeating the identical attempt changes nothing.
            break
        fi
    done

    return 1
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

    # ------------------------------------------------------------------
    # Saved profile: reuse it, re-key it, or drop it
    # ------------------------------------------------------------------
    local needs_pass=false
    if echo "$security" | grep -qiE 'WPA|WEP|WPA2|WPA3|SAE|PSK|802.1X'; then
        needs_pass=true
    fi

    # pre_uuid is what was saved before this attempt touched anything; it
    # decides later whether a leftover profile may be cleaned up.
    local pre_uuid original_uuid pass="" ask_pass=true action="" connected=false
    pre_uuid=$(find_connection_uuid "$ssid")
    original_uuid="$pre_uuid"

    if [ -n "$original_uuid" ]; then
        local stored_km
        stored_km=$(connection_key_mgmt "$original_uuid")
        echo ""
        echo "  This network already has a saved profile (UUID $original_uuid,"
        echo "  saved security: ${stored_km:-open/none})."
        echo "  Enter = use the saved credentials   p = type the password again   d = delete the saved profile"
        read -p "  Choice [Enter/p/d]: " action
        case "$action" in
            p|P)
                prompt_password "$ssid"
                pass="$PROMPTED_PASSWORD"
                # Answer already given: do not ask a second time below.
                ask_pass=false
                ;;
            d|D)
                if confirm_yes "  Delete the saved profile for '$ssid'?" n; then
                    if nmcli connection delete "$original_uuid" >/dev/null 2>&1; then
                        echo "  Deleted the saved profile (UUID $original_uuid)."
                        original_uuid=""
                    else
                        echo -e "  ${RED}ERROR${NC}: could not delete UUID $original_uuid - keeping it."
                    fi
                else
                    echo "  Keeping the saved profile."
                fi
                ;;
            *)
                echo "  Using the stored credentials."
                ask_pass=false
                ;;
        esac
    fi

    if $ask_pass; then
        if $needs_pass; then
            prompt_password "$ssid"
            pass="$PROMPTED_PASSWORD"
        else
            echo "This network appears to be open (no password required)."
            read -p "Press Enter to continue with open network, or type a password if you know one is needed: " pass
            echo ""
            [ -n "$pass" ] && needs_pass=true
        fi
    fi

    # ------------------------------------------------------------------
    # Connect (retrying a rejected password instead of storing it forever)
    # ------------------------------------------------------------------
    if wifi_connect_with_retry "$iface" "$ssid" "$original_uuid" "$pass" \
                              "$needs_pass" "$pre_uuid"; then
        connected=true
    fi

    if ! $connected; then
        echo ""
        echo -e "ERROR: Could not connect to ${BOLD}${ssid}${NC}."
        # Look at what actually survived the attempt instead of assuming.
        local left_uuid
        left_uuid=$(find_connection_uuid "$ssid")
        if [ -n "$left_uuid" ]; then
            echo "       A profile is still saved (UUID $left_uuid)."
            if confirm_yes "       Delete it so it stops auto-retrying?" n; then
                if nmcli connection delete "$left_uuid" >/dev/null 2>&1; then
                    echo "       Deleted the saved profile (UUID $left_uuid)."
                else
                    echo "       Delete failed; the profile is still saved."
                fi
            fi
        else
            echo "       No profile was left behind, so the wrong password is not saved."
        fi
        if [ -n "$default_conn" ] && [ "$default_conn" != "$ssid" ]; then
            rejoin_default_wifi "$iface" "$default_conn"
        fi
        echo "*****************************************************"
        return 1
    fi

    if internet_ok; then
        echo -e "SUCCESS: ${GREEN}Connected${NC} to ${BOLD}${ssid}${NC} and internet is reachable."
        echo "         Network saved. It will auto-connect on future boots."
    else
        echo -e "SUCCESS: ${GREEN}Connected${NC} to ${BOLD}${ssid}${NC} (saved for auto-connect), but internet check failed."
        echo "         (You may be behind a captive portal or have no upstream route yet.)"
    fi

    echo "*****************************************************"
    echo "Tip: Use 'Show status' to verify. Menu option 6 sets the order the saved"
    echo "     networks are tried in on boot (1 = first), so the right one wins."
    echo "*****************************************************"
}

list_saved_networks() {
    echo "*****************************************************"
    echo "LIST SAVED NETWORKS (from NetworkManager)"
    echo "*****************************************************"

    local saved active_uuid
    saved=$(nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null | grep ':802-11-wireless$')
    active_uuid=$(active_wifi_uuid)

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
        local n_name n_uuid n_marker
        n_name=$(printf '%s' "$line" | cut -d: -f1)
        n_uuid=$(printf '%s' "$line" | cut -d: -f2)
        printf '%s\n' "$n_uuid" >> "$nids_file"
        n_marker=""
        [ "$n_uuid" = "$active_uuid" ] && n_marker=" ${YELLOW}${BOLD}(connected)${NC}"
        local autoconnect prio
        autoconnect=$(nmcli -t -f connection.autoconnect connection show "$n_uuid" 2>/dev/null | nm_field)
        prio=$(connection_priority "$n_uuid")
        printf "%2d. ${BOLD}%-28s${NC} [%s] autoconnect=%s priority=%s%b\n" "$count" "$n_name" "$n_uuid" "${autoconnect:-?}" "$prio" "$n_marker"
    done <<< "$saved"
    echo "-----------------------------------------------------"

    echo "Enter a number to connect, or 'X' to return."
    echo "(Delete one: menu option 5. Change which is tried first: menu option 6.)"
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

    local ifaces iface default_conn selected_name needs_pass
    ifaces=$(get_wifi_ifaces)
    iface=$(echo "$ifaces" | awk '{print $1}')
    default_conn=$(get_active_ssid "$iface")
    selected_name=$(nmcli -t -f connection.id connection show "$selected_uuid" 2>/dev/null | nm_field)
    [ -z "$selected_name" ] && selected_name="$selected_uuid"
    needs_pass=$(connection_needs_password "$selected_uuid")

    echo ""
    echo -e "Connecting to saved network ${BOLD}${selected_name}${NC} (UUID $selected_uuid)..."

    if wifi_connect_with_retry "$iface" "$selected_name" "$selected_uuid" "" \
                              "$needs_pass" "$selected_uuid"; then
        if internet_ok; then
            echo -e "SUCCESS: ${GREEN}Connected${NC} and internet is reachable."
        else
            echo -e "SUCCESS: ${GREEN}Connected${NC}, but internet check failed."
            echo "         (You may be behind a captive portal or have no upstream route yet.)"
        fi
    else
        echo -e "ERROR: Could not bring up ${BOLD}${selected_name}${NC}."
        if confirm_yes "Delete the saved profile for '$selected_name' (removes its stored password)?" n; then
            if nmcli connection delete "$selected_uuid" >/dev/null 2>&1; then
                echo "  Deleted the saved profile (UUID $selected_uuid)."
            else
                echo "  Delete failed; the profile is still saved."
            fi
        fi
        if [ -n "$default_conn" ] && [ "$default_conn" != "$selected_name" ]; then
            rejoin_default_wifi "$iface" "$default_conn"
        fi
    fi

    echo "*****************************************************"
}


prioritize_saved_networks() {
    echo "*****************************************************"
    echo "PRIORITIZE SAVED NETWORKS (auto-connect order)"
    echo "*****************************************************"

    local order_file count choice target moved_uuid moved_name auto
    if [ -z "$(saved_wifi_order)" ]; then
        echo "No saved WiFi networks yet."
        echo "Join one first (menu option 3); it is saved and can be ranked here."
        echo "*****************************************************"
        return 0
    fi

    order_file=$(mktemp /tmp/wifi-prio-XXXXXX) || { echo "ERROR: cannot create temp file"; return 1; }

    echo "Rank 1 is the network tried first; 2 is the fallback after it, and so on."
    echo "NetworkManager joins the highest-ranked saved network that is in range."
    echo ""

    while true; do
        echo "Saved networks, in the order they are tried:"
        echo "-----------------------------------------------------"
        show_priority_list "$order_file"
        count=$(grep -c . "$order_file")
        echo "-----------------------------------------------------"
        echo "Enter a network number to move it, A to re-rank by last used, X to finish."
        read -p "Move network (1-$count) / A / X: " choice

        case "$choice" in
            x|X|exit|Exit|EXIT|'')
                break
                ;;
            a|A)
                apply_last_used_order "$order_file"
                # shellcheck disable=SC2046
                if apply_autoconnect_order $(cat "$order_file"); then
                    echo "  Re-ranked by last used (most recently joined = 1)."
                else
                    echo "  WARNING: NetworkManager rejected some of the new ranks."
                fi
                continue
                ;;
            *[!0-9]*)
                echo "Invalid choice."
                continue
                ;;
        esac

        if [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
            echo "Invalid choice."
            continue
        fi

        read -p "New position for rank $choice (1-$count): " target
        case "$target" in
            ''|*[!0-9]*) echo "Invalid position. Nothing changed."; continue ;;
        esac
        if [ "$target" -lt 1 ] || [ "$target" -gt "$count" ]; then
            echo "Invalid position. Nothing changed."
            continue
        fi
        if [ "$target" -eq "$choice" ]; then
            echo "Rank $choice is already at position $choice. Nothing changed."
            continue
        fi

        moved_uuid=$(sed -n "${choice}p" "$order_file")
        reorder_uuid_file "$order_file" "$choice" "$target"
        # shellcheck disable=SC2046
        if apply_autoconnect_order $(cat "$order_file"); then
            echo "  Moved to position $target; the new order is applied."
        else
            echo "  WARNING: NetworkManager rejected some of the new ranks."
        fi

        # A profile with autoconnect=no is skipped at boot, so its rank would
        # silently do nothing. Offer to switch it on - never without asking.
        auto=$(nmcli -t -f connection.autoconnect connection show "$moved_uuid" 2>/dev/null | nm_field)
        if [ "$auto" = "no" ]; then
            moved_name=$(nmcli -t -f connection.id connection show "$moved_uuid" 2>/dev/null | nm_field)
            [ -z "$moved_name" ] && moved_name="$moved_uuid"
            if confirm_yes "$moved_name has autoconnect=no, so it is skipped at boot. Turn autoconnect on?" y; then
                nmcli connection modify "$moved_uuid" connection.autoconnect yes >/dev/null 2>&1 \
                    && echo "  autoconnect enabled for $moved_name." \
                    || echo "  WARNING: could not enable autoconnect for $moved_name."
            fi
        fi
    done

    echo ""
    echo "Final order:"
    echo "-----------------------------------------------------"
    show_priority_list "$order_file"
    echo "-----------------------------------------------------"
    rm -f "$order_file"
    echo -e "SUCCESS: the order is stored in NetworkManager (${BOLD}connection.autoconnect-priority${NC})"
    echo "         and is re-read on every boot, so it survives reboots."
    echo "*****************************************************"
}

delete_saved_network() {
    echo "*****************************************************"
    echo "DELETE A SAVED WIFI NETWORK"
    echo "*****************************************************"

    local saved
    saved=$(nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null | grep ':802-11-wireless$')

    if [ -z "$saved" ]; then
        echo "No saved WiFi networks."
        echo "*****************************************************"
        return
    fi

    local active_uuid
    active_uuid=$(active_wifi_uuid)

    local uuids_file count=0
    uuids_file=$(mktemp /tmp/wifi-del-XXXXXX) || { echo "ERROR: cannot create temp file"; return; }

    echo "Saved networks:"
    echo "-----------------------------------------------------"
    while IFS= read -r line; do
        count=$((count + 1))
        local n_name n_uuid n_marker=""
        n_name=$(printf '%s' "$line" | cut -d: -f1)
        n_uuid=$(printf '%s' "$line" | cut -d: -f2)
        printf '%s\n' "$n_uuid" >> "$uuids_file"
        [ "$n_uuid" = "$active_uuid" ] && n_marker=" ${YELLOW}${BOLD}(connected now)${NC}"
        printf "%2d. ${BOLD}%-28s${NC} [%s]%b\n" "$count" "$n_name" "$n_uuid" "$n_marker"
    done <<< "$saved"
    echo "-----------------------------------------------------"

    local choice
    read -p "Enter number of the saved network to delete (or X to cancel): " choice
    case "$choice" in
        x|X|exit|Exit|EXIT)
            echo "Cancelled. Nothing was deleted."
            rm -f "$uuids_file"
            return 0
            ;;
        ''|*[!0-9]*)
            echo "Invalid choice."
            rm -f "$uuids_file"
            return 0
            ;;
    esac
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        echo "Invalid choice."
        rm -f "$uuids_file"
        return 0
    fi

    local sel_uuid sel_name sel_auto sel_ts sel_last
    sel_uuid=$(sed -n "${choice}p" "$uuids_file")
    rm -f "$uuids_file"

    sel_name=$(nmcli -t -f connection.id connection show "$sel_uuid" 2>/dev/null | nm_field)
    [ -z "$sel_name" ] && sel_name="(unnamed)"
    sel_auto=$(nmcli -t -f connection.autoconnect connection show "$sel_uuid" 2>/dev/null | nm_field)
    sel_ts=$(nmcli -t -f connection.timestamp connection show "$sel_uuid" 2>/dev/null | nm_field)
    if [ -n "$sel_ts" ] && [ "$sel_ts" != "0" ]; then
        sel_last=$(date -d "@${sel_ts}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
    else
        sel_last="never"
    fi

    echo ""
    echo "  About to delete this saved profile:"
    echo "    Network:     ${BOLD}${sel_name}${NC}"
    echo "    UUID:        $sel_uuid"
    echo "    Autoconnect: ${sel_auto:-?}"
    echo "    Last used:   $sel_last"
    if [ "$sel_uuid" = "$active_uuid" ]; then
        echo -e "    ${YELLOW}This is the network the machine is connected to right now.${NC}"
    fi
    echo ""
    echo "  The saved profile (including its stored password) is removed from"
    echo "  NetworkManager. The access point itself is not touched."
    echo ""

    # Confirmation. A bare Enter never deletes anything.
    if ! confirm_yes "Delete the saved profile for '$sel_name'?" n; then
        echo "Cancelled. Nothing was deleted."
        echo "*****************************************************"
        return 0
    fi

    if [ "$sel_uuid" = "$active_uuid" ]; then
        if ! confirm_yes "That profile carries your current connection and will disconnect you. Delete anyway?" n; then
            echo "Cancelled. Nothing was deleted."
            echo "*****************************************************"
            return 0
        fi
    fi

    local out rc
    out=$(nmcli connection delete "$sel_uuid" 2>&1); rc=$?
    [ -n "$out" ] && echo "  $out"

    if [ "$rc" -eq 0 ] && ! nmcli -t -f UUID connection show 2>/dev/null | grep -qx "$sel_uuid"; then
        echo -e "SUCCESS: ${GREEN}Deleted${NC} saved network ${BOLD}${sel_name}${NC} (UUID $sel_uuid)."
    else
        echo -e "ERROR: Could not delete UUID $sel_uuid - see the message above."
    fi
    echo "*****************************************************"
}

# ------------------------------------------------------------------
# Non-interactive mode (--status): print the connection summary and exit.
# This is exactly what the first terminal of a session dumps after the
# fastfetch splash, so 'wifi --status' reproduces it by hand.
# ------------------------------------------------------------------
if $STATUS_ONLY; then
    echo
    quick_wifi_summary
    if [ -n "$(get_wifi_ifaces)" ]; then
        echo ""
        connection_details
    fi
    exit 0
fi

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
    echo "4. List saved networks (connect to one)"
    echo "5. Delete a saved network (asks for confirmation first)"
    echo "6. Prioritize saved networks (rank 1 = tried first on boot)"
    echo "X. Exit"
    echo "*****************************************************"

    read -p "Enter choice [1-6 or X]: " choice

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
        5)
            delete_saved_network
            ;;
        6)
            prioritize_saved_networks
            ;;
        x|X|exit|Exit|EXIT)
            echo ""
            echo "Exiting WiFi Manager."
            echo "Full session log is in: $LOG_FILE"
            exit 0
            ;;
        *)
            echo "Invalid choice. Please enter a number 1-6 or X."
            ;;
    esac
done
