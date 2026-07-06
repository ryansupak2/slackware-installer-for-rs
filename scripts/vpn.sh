#!/bin/bash
# vpn - NordVPN (OpenVPN) connect/disconnect/status by country code
#
# Usage:
#   vpn us              Connect to US (tries up to 3 servers, exits after)
#   vpn disconnect      Disconnect
#   vpn status          Show connection status
#   vpn                 Interactive menu (no args)

export PATH="/usr/sbin:/sbin:$PATH"

# ── Configuration ──────────────────────────────────────────────────────
CONFIG_DIR="/etc/openvpn/configs/udp/ovpn_udp"
AUTH_FILE="/etc/openvpn/nordvpn-auth.txt"
DNS_FILE="/etc/openvpn/nordvpn-dns-by-country.txt"
MAX_TRIES=5
CONNECT_TIMEOUT=15
LOG_DIR="$HOME/logs"
LOG_FILE="$LOG_DIR/vpn-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"

# Redirect all output to both screen and log (matching wifi-manager / dwl-start pattern)
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
    echo -e "[\$ts] [\$level] \$msg"
}

# ── Privilege helpers ──────────────────────────────────────────────────
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    elif command -v doas >/dev/null 2>&1; then
        doas "$@"
    else
        log_msg ERROR "not root and neither sudo nor doas installed"
        return 1
    fi
}

# ── State checks ───────────────────────────────────────────────────────
is_connected() {
    ip link show tun0 2>/dev/null | grep -q '<.*UP.*>'
}

has_configs() {
    [ -d "$CONFIG_DIR" ] && ls "$CONFIG_DIR"/*.ovpn >/dev/null 2>&1
}

# ── Killswitch (block non-VPN traffic when tunnel is up) ───────────────
enable_killswitch() {
    # Allow loopback
    as_root /sbin/iptables -I OUTPUT 1 -o lo -j ACCEPT 2>/dev/null || true
    # Allow tunnel interface
    as_root /sbin/iptables -I OUTPUT 2 -o tun0 -j ACCEPT 2>/dev/null || true
    # Allow already-established connections (critical: existing flows stay alive)
    as_root /sbin/iptables -I OUTPUT 3 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    # Block everything else
    as_root /sbin/iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited 2>/dev/null || true
    # IPv6: drop all
    as_root /sbin/ip6tables -A OUTPUT -j DROP 2>/dev/null || true
    log_msg INFO "Killswitch ON — only VPN traffic allowed"
}

disable_killswitch() {
    as_root /sbin/iptables -D OUTPUT -o lo -j ACCEPT 2>/dev/null || true
    as_root /sbin/iptables -D OUTPUT -o tun0 -j ACCEPT 2>/dev/null || true
    as_root /sbin/iptables -D OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    as_root /sbin/iptables -D OUTPUT -j REJECT --reject-with icmp-admin-prohibited 2>/dev/null || true
    as_root /sbin/ip6tables -D OUTPUT -j DROP 2>/dev/null || true
    log_msg INFO "Killswitch OFF"
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
        sed -i '/^auth-user-pass/d' "$tmpcfg"
        echo "auth-user-pass $AUTH_FILE" >> "$tmpcfg"
        echo "redirect-gateway ipv6" >> "$tmpcfg"

        # Launch daemonized
        if ! as_root openvpn --config "$tmpcfg" --daemon; then
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
                enable_killswitch
                return 0
            fi
        done

        echo -e "${RED}timeout${NC}"
        as_root pkill openvpn 2>/dev/null || true
    done

    log_msg ERROR "failed to connect after $tried attempt(s)"
    return 1
}

# ── Disconnect ─────────────────────────────────────────────────────────
disconnect_vpn() {
    disable_killswitch
    as_root pkill openvpn 2>/dev/null || true
    sleep 0.5
    as_root pkill -f 'openvpn.*ovpn' 2>/dev/null || true
    sleep 1
    as_root pkill -9 openvpn 2>/dev/null || true
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
            echo -e "Status: ${GREEN}CONNECTED${NC}"
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
        disconnect|down|d)
            disconnect_vpn
            ;;
        status|st|s)
            if is_connected; then
                echo -e "VPN: ${GREEN}CONNECTED${NC} (tun0 is UP)"
                ip addr show tun0 2>/dev/null | grep inet
            else
                echo -e "VPN: ${RED}DISCONNECTED${NC}"
            fi
            ;;
        *)
            # Assume it's a country code
            if [ ${#1} -ne 2 ]; then
                echo "Usage: vpn [us|uk|mx|...]   connect to country"
                echo "       vpn disconnect       disconnect"
                echo "       vpn status           show status"
                echo "       vpn                  interactive menu"
                exit 1
            fi
            if is_connected; then
                log_msg INFO "already connected — disconnecting first"
                disconnect_vpn
                sleep 1
            fi
            if connect_country "$1"; then
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


