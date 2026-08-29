#!/bin/bash
# vpn - NordVPN (OpenVPN) connect/disconnect/status by country code
#
# Usage:
#   vpn us              Connect to US (tries up to 3 servers, exits after)
#   vpn list            List available country codes
#   vpn stop            Disconnect
#   vpn status          Show connection status

export PATH="/usr/sbin:/sbin:$PATH"

# ── Configuration ──────────────────────────────────────────────────────
CONFIG_DIR="/etc/openvpn/configs/udp/ovpn_udp"
AUTH_FILE="/etc/openvpn/nordvpn-auth.txt"
DNS_FILE="/etc/openvpn/nordvpn-dns-by-country.txt"
STATE_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vpn_state"
MAX_TRIES=5
CONNECT_TIMEOUT=15
LOG_DIR="/var/log/${USER:-root}"
LOG_FILE="$LOG_DIR/vpn-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
# Redirect all output to both screen and log (matching wifi-manager pattern)
exec > >(tee -a "$LOG_FILE") 2>&1

# Terminal formatting (matching wifi-manager)
BOLD='\033[1m'
GREEN='\033[32m'
RED='\033[31m'
NC='\033[0m'

# ── Logging ────────────────────────────────────────────────────────────
log_msg() {
    local level="$1"; shift
    local msg="$*"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[${ts}] [${level}] ${msg}"
}

# ── Privilege helpers ──────────────────────────────────────────────────
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -n "$@"
    elif command -v doas >/dev/null 2>&1; then
        doas -n "$@"
    else
        log_msg ERROR "not root and neither sudo nor doas installed"
        return 1
    fi
}

# ── State checks ───────────────────────────────────────────────────────
is_connected() {
    /usr/sbin/ip link show tun0 2>/dev/null | grep -q '<.*UP.*>'
}

# Check if tun0 is UP AND the VPN tunnel actually passes traffic
is_vpn_alive() {
    is_connected || return 1
    ping -c1 -W2 1.1.1.1 >/dev/null 2>&1
}

# Check if the current user owns the running openvpn process
owns_vpn() {
    local ovpn_pid
    ovpn_pid=$(pgrep -x openvpn | head -1)
    [ -z "$ovpn_pid" ] && return 0   # no process = not owned by anyone = safe to take over
    [ "$(ps -o user= -p "$ovpn_pid" 2>/dev/null)" = "$(whoami)" ]
}

has_configs() {
    [ -d "$CONFIG_DIR" ] && find "$CONFIG_DIR" -maxdepth 1 -name '*.ovpn' -print -quit | grep -q .
}

# ── Country name mapping ───────────────────────────────────────────────
declare -A COUNTRY_NAMES=(
    [al]="Albania" [dz]="Algeria" [ar]="Argentina" [au]="Australia"
    [at]="Austria" [be]="Belgium" [ba]="Bosnia and Herzegovina"
    [br]="Brazil" [bg]="Bulgaria" [ca]="Canada" [cl]="Chile" [co]="Colombia"
    [cr]="Costa Rica" [hr]="Croatia" [cy]="Cyprus" [cz]="Czech Republic"
    [dk]="Denmark" [eg]="Egypt" [ee]="Estonia" [fi]="Finland" [fr]="France"
    [ge]="Georgia" [de]="Germany" [gr]="Greece" [hk]="Hong Kong"
    [hu]="Hungary" [is]="Iceland" [in]="India" [id]="Indonesia" [ie]="Ireland"
    [il]="Israel" [it]="Italy" [jp]="Japan" [kz]="Kazakhstan" [lv]="Latvia"
    [lt]="Lithuania" [lu]="Luxembourg" [my]="Malaysia" [mx]="Mexico"
    [md]="Moldova" [nl]="Netherlands" [nz]="New Zealand"
    [mk]="North Macedonia" [no]="Norway" [pl]="Poland" [pt]="Portugal"
    [ro]="Romania" [rs]="Serbia" [sg]="Singapore" [sk]="Slovakia"
    [si]="Slovenia" [za]="South Africa" [kr]="South Korea" [es]="Spain"
    [se]="Sweden" [ch]="Switzerland" [tw]="Taiwan" [th]="Thailand"
    [tr]="Turkey" [ua]="Ukraine" [ae]="United Arab Emirates"
    [gb]="United Kingdom" [us]="United States" [vn]="Vietnam"
)

country_name() {
    local cc="$1"
    echo "${COUNTRY_NAMES[$cc]:-$cc}"
}

# ── List ───────────────────────────────────────────────────────────────
list_countries() {
    if [ ! -f "$DNS_FILE" ]; then
        log_msg ERROR "country file not found: $DNS_FILE"
        return 1
    fi
    echo "Available country codes (abbreviation: country):"
    echo ""
    while IFS=: read -r cc _; do
        cc=$(echo "$cc" | tr '[:upper:]' '[:lower:]')
        printf '  %-4s %s\n' "$cc" "$(country_name "$cc")"
    done < "$DNS_FILE"
}

print_usage() {
    echo "Usage: vpn <country>     connect to country (e.g. us, uk, mx, jp)"
    echo "       vpn list          list available country codes"
    echo "       vpn stop          disconnect"
    echo "       vpn status        show connection status"
    echo "       vpn               interactive menu"
}

# ── IPv6 leak prevention ───────────────────────────────────────────────
block_ipv6() {
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -vE '^lo$|^tun'); do
        as_root /sbin/sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=1" >/dev/null 2>&1
    done
}

restore_ipv6() {
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -vE '^lo$|^tun'); do
        as_root /sbin/sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=0" >/dev/null 2>&1
    done
}

get_country_dns() {
    local cc="$1"
    grep "^${cc}:" "$DNS_FILE" 2>/dev/null | cut -d: -f2 | xargs || echo ""
}

# ── Connect ────────────────────────────────────────────────────────────
connect_country() {
    local cc="$1"
    cc=$(echo "$cc" | tr '[:upper:]' '[:lower:]')

    local dns
    dns=$(get_country_dns "$cc")

    local files=("$CONFIG_DIR"/${cc}*.ovpn)
    if [ ${#files[@]} -eq 0 ] || [ ! -f "${files[0]}" ]; then
        log_msg ERROR "no configs for country: $cc"
        return 1
    fi

    local shuffled=($(printf '%s\n' "${files[@]}" | shuf))
    local tried=0

    for config in "${shuffled[@]}"; do
        [ $tried -ge $MAX_TRIES ] && break
        tried=$((tried + 1))

        local server
        server=$(basename "$config" .ovpn)

        echo -n "Connecting to ${server}... "

        # Build temp config
        local tmpcfg
        tmpcfg=$(mktemp /tmp/ovpn-XXXXXX) || { log_msg ERROR "cannot create temp file"; continue; }
        cp "$config" "$tmpcfg"
        if [ -n "$dns" ]; then
            echo "dhcp-option DNS $dns" >> "$tmpcfg"
        fi
        # Strip deprecated NordVPN options that spam stderr
        sed -i '/^persist-key$/d; /^fast-io$/d' "$tmpcfg"
        sed -i '/^auth-user-pass/d' "$tmpcfg"
        echo "auth-user-pass $AUTH_FILE" >> "$tmpcfg"
        echo "redirect-gateway ipv6" >> "$tmpcfg"

        # Launch daemonized
        if ! as_root /usr/sbin/openvpn --config "$tmpcfg" --daemon; then
            log_msg ERROR "openvpn failed to start for $server"
            continue
        fi

        # Poll for tun0 to come up
        local waited=0
        while [ $waited -lt $CONNECT_TIMEOUT ]; do
            sleep 1
            waited=$((waited + 1))
            if is_connected; then
                echo -e "${GREEN}done${NC} (${waited}s)"
                block_ipv6
                echo "$cc" > "$STATE_FILE"
                return 0
            fi
        done

        echo -e "${RED}timeout${NC}"
        as_root /usr/bin/pkill openvpn 2>/dev/null || true
    done

    log_msg ERROR "failed to connect after $tried attempt(s)"
    return 1
}

# ── Disconnect ─────────────────────────────────────────────────────────
disconnect_vpn() {
    restore_ipv6
    rm -f "$STATE_FILE"
    as_root /usr/bin/pkill openvpn 2>/dev/null || true
    sleep 0.5
    as_root /usr/bin/pkill -f 'openvpn.*ovpn' 2>/dev/null || true
    sleep 1
    as_root /usr/bin/pkill -9 openvpn 2>/dev/null || true
    sleep 1

    if ! is_connected; then
        echo -e "${RED}DISCONNECTED${NC}"
        return 0
    else
        log_msg ERROR "tun0 still up after kill — run: sudo pkill -9 openvpn"
        return 1
    fi
}

# ── Interactive menu ───────────────────────────────────────────────────
interactive_menu() {
    while true; do
        echo ""
        echo "NordVPN (OpenVPN)"
        echo "=================="
        echo ""

        if is_connected; then
            if is_vpn_alive; then
                echo -e "Status: ${GREEN}CONNECTED${NC}"
            else
                echo -e "Status: ${RED}STALE${NC} (tun0 UP, no internet — press 1 to disconnect)"
            fi
            echo ""
            echo "1. Disconnect"
            echo "2. Exit"
            echo ""
            read -p "Choice [1-2]: " choice
            case $choice in
                1) echo ""; disconnect_vpn ;;
                2) echo ""; return 0 ;;
            esac
        else
            echo -e "Status: ${RED}DISCONNECTED${NC}"
            echo ""
            echo "1. Connect by country code"
            echo "2. Exit"
            echo ""
            read -p "Choice [1-2]: " choice
            case $choice in
                1)
                    echo ""
                    read -p "Enter 2-letter country code (e.g. us, uk, mx, jp): " cc
                    if [ ${#cc} -eq 2 ]; then
                        connect_country "$cc"
                    else
                        echo "Invalid country code."
                    fi
                    ;;
                2) echo ""; return 0 ;;
                *) echo "Invalid choice" ;;
            esac
        fi
    done
}

# ── CLI mode ───────────────────────────────────────────────────────────
run_cli() {
    case "$1" in
        stop|disconnect|down|d)
            disconnect_vpn
            ;;
        list)
            list_countries
            ;;
        --help)
            print_usage
            exit 0
            ;;
        status|st|s)
            if is_connected; then
                if is_vpn_alive; then
                    echo -e "VPN: ${GREEN}CONNECTED${NC} (tun0 is UP)"
                else
                    echo -e "VPN: ${RED}STALE${NC} (tun0 is UP, but no internet — run 'vpn disconnect' to recover)"
                fi
                ip addr show tun0 2>/dev/null | grep inet
            else
                echo -e "VPN: ${RED}DISCONNECTED${NC}"
            fi
            ;;
        *)
            # Assume it's a country code
            if [ ${#1} -ne 2 ]; then
                print_usage
                exit 1
            fi
            if is_connected; then
                if owns_vpn; then
                    log_msg INFO "already connected — disconnecting first"
                    disconnect_vpn
                    sleep 1
                else
                    log_msg ERROR "VPN is active under another user — refusing to disconnect"
                    echo "VPN is connected by another user. Run 'vpn disconnect' as that user first."
                    exit 1
                fi
            fi
            if connect_country "$1"; then
                echo "$1" > "$STATE_FILE"
                echo "Run 'vpn disconnect' to stop."
            else
                exit 1
            fi
            ;;
    esac
}

# ── Entry point ────────────────────────────────────────────────────────
if ! has_configs; then
    echo "No OpenVPN configs found."
    echo "Run the OpenVPN (NordVPN) setup step first."
    exit 1
fi

if [ $# -eq 0 ]; then
    interactive_menu
else
    run_cli "$1"
fi


