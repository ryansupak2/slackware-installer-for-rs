#!/bin/bash
# vpn - NordVPN (OpenVPN) connect/disconnect/status by country code
#
# Usage:
#   vpn                 status summary + interactive menu (X to exit)
#   vpn status          detailed status: country, server, endpoint, egress IP
#   vpn us              connect to US (tries up to 5 servers)
#   vpn list            list available country codes
#   vpn stop            disconnect
#
# Status output follows the same visual language as wifi-manager.sh:
#   * colors only when stdout is a TTY (logs and pipes stay plain text),
#   * aligned "Label:   value" lines, lowercase state words,
#   * bold values, YELLOW tags for the thing that needs attention,
#   * banner-wrapped sections, "----- Device: X -----" detail blocks.
# Keep it that way: `wifi-manager` and `vpn` are read side by side.

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

# Terminal formatting (colors only when stdout is a TTY, so logs stay clean).
# MUST be computed before the tee redirect below — after it, stdout is a pipe
# and every status line would lose its color.
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

# Redirect all output to both screen and log (matching wifi-manager pattern)
exec > >(tee -a "$LOG_FILE") 2>&1

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

# ── Tunnel introspection ───────────────────────────────────────────────
# Everything below reads state; nothing here changes the connection.
ovpn_pid() { pgrep -x openvpn | head -1; }

# The config the daemon actually runs: connect_country writes a temp copy
# (so the original server filename is not in the process arguments).
ovpn_config_path() {
    local pid cfg
    pid=$(ovpn_pid)
    [ -n "$pid" ] || return 1
    cfg=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | awk '/^--config$/{getline; print; exit}')
    [ -n "$cfg" ] || return 1
    echo "$cfg"
}

# "ip port" of the far end, from the running config
ovpn_remote() {
    local cfg
    cfg=$(ovpn_config_path) || return 1
    awk '/^remote[ \t]/{print $2, $3; exit}' "$cfg" 2>/dev/null
}

ovpn_proto() {
    local cfg
    cfg=$(ovpn_config_path) || return 1
    awk '/^proto[ \t]/{print $2; exit}' "$cfg" 2>/dev/null
}

ovpn_uptime() {
    local pid
    pid=$(ovpn_pid)
    [ -n "$pid" ] || return 1
    ps -o etime= -p "$pid" 2>/dev/null | tr -d ' '
}

ovpn_started() {
    local pid
    pid=$(ovpn_pid)
    [ -n "$pid" ] || return 1
    ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//'
}

tun0_ip() {
    /usr/sbin/ip -4 -o addr show tun0 2>/dev/null | awk '{print $4; exit}'
}

tun0_mtu() {
    /usr/sbin/ip -o link show tun0 2>/dev/null | sed -n 's/.*mtu \([0-9]*\).*/\1/p' | head -1
}

# Map the daemon's remote IP back to the config file that produced it, so the
# status can name the server even for a tunnel this shell did not start.
server_for_remote() {
    local ip="$1" hit
    [ -n "$ip" ] || return 1
    hit=$(grep -lE "^remote[[:space:]]+${ip//./\\.}([[:space:]]|$)" "$CONFIG_DIR"/*.ovpn 2>/dev/null | head -1)
    [ -n "$hit" ] || return 1
    basename "$hit" .ovpn
}

# State file: key=value lines written by connect_country. Older files hold a
# bare country code; state_value keeps reading both.
state_value() {   # $1 = key
    [ -f "$STATE_FILE" ] || return 1
    case "$(head -1 "$STATE_FILE")" in
        *=*) sed -n "s/^$1=//p" "$STATE_FILE" | head -1 ;;
        *) [ "$1" = "cc" ] && head -1 "$STATE_FILE" ;;
    esac
}

write_state() {   # $1=cc $2=server $3=config $4=remote
    {
        echo "cc=$1"
        echo "server=$2"
        echo "config=$3"
        echo "remote=$4"
        echo "started=$(date +%s)"
    } > "$STATE_FILE" 2>/dev/null || true
}

# Best-effort geo lookup of the egress IP — i.e. where the internet thinks you
# are right now. 3s timeout, silent on failure, VPN_NO_GEO=1 to skip entirely.
egress_geo() {
    [ "${VPN_NO_GEO:-0}" = "1" ] && return 1
    command -v curl >/dev/null 2>&1 || return 1
    local json
    json=$(timeout 3 curl -s https://ipinfo.io/json 2>/dev/null) || return 1
    [ -n "$json" ] || return 1
    local ip city region country
    ip=$(printf '%s\n' "$json" | sed -n 's/.*"ip": *"\([^"]*\)".*/\1/p' | head -1)
    city=$(printf '%s\n' "$json" | sed -n 's/.*"city": *"\([^"]*\)".*/\1/p' | head -1)
    region=$(printf '%s\n' "$json" | sed -n 's/.*"region": *"\([^"]*\)".*/\1/p' | head -1)
    country=$(printf '%s\n' "$json" | sed -n 's/.*"country": *"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$ip" ] || return 1
    printf '%s\t%s\t%s\t%s' "$ip" "$city" "$region" "$country"
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

# ── Status presentation (mirrors wifi-manager.sh) ──────────────────────
# Where the tunnel exits, in words: "Mexico (mx)". Falls back to the server
# hostname, then to the egress country, then to a plain "unknown location".
vpn_where() {
    local cc server ip geo country
    cc=$(state_value cc 2>/dev/null)
    server=$(state_value server 2>/dev/null)
    [ -n "$server" ] || server=$(server_for_remote "$(ovpn_remote 2>/dev/null | awk '{print $1}')" 2>/dev/null)
    if [ -z "$cc" ] && [ -n "$server" ]; then
        cc=$(printf '%s' "$server" | sed -n 's/^\([a-z][a-z]\)[0-9].*/\1/p')
    fi
    if [ -z "$cc" ] && geo=$(egress_geo); then
        country=$(printf '%s' "$geo" | cut -f4)
        cc=$(printf '%s' "$country" | tr '[:upper:]' '[:lower:]')
    fi
    if [ -n "$cc" ] && [ -n "$(country_name "$cc")" ]; then
        printf '%s (%s)' "$(country_name "$cc")" "$cc"
    else
        printf 'unknown location'
    fi
}

vpn_server() {
    local server rip
    server=$(state_value server 2>/dev/null)
    if [ -z "$server" ]; then
        rip=$(ovpn_remote 2>/dev/null | awk '{print $1}')
        server=$(server_for_remote "$rip" 2>/dev/null)
    fi
    printf '%s' "${server:-unknown server}"
}

# Compact summary — the equivalent of wifi-manager's quick_wifi_summary().
# Shown at the top of the menu and after connect/disconnect.
quick_vpn_summary() {
    if ! is_connected; then
        echo -e "VPN:     ${RED}not connected${NC}  (traffic goes out directly)"
        return
    fi

    local tag="" remote rip rport proto geo gip gcity gregion gcc geo_line tip
    tip=$(tun0_ip)
    remote=$(ovpn_remote 2>/dev/null)
    rip=${remote%% *}
    rport=${remote##* }
    proto=$(ovpn_proto 2>/dev/null)

    if is_vpn_alive; then
        tag=" ${BOLD}${YELLOW}[Internet]${NC}"
    else
        tag=" ${BOLD}${YELLOW}[STALE]${NC}"
    fi
    local srv srv_tag=""
    srv=$(vpn_server)
    # The server name is only known for tunnels this script started (it is
    # recorded in the state file). Otherwise it is matched from the config's
    # remote IP, which can name a different box in the same pool — say so
    # instead of pretending to know.
    [ -n "$(state_value server 2>/dev/null)" ] || srv_tag=" ${YELLOW}[inferred]${NC}"

    echo -e "VPN:     ${GREEN}connected${NC}  to ${BOLD}$(vpn_where)${NC}${tag}"
    echo -e "Server:  ${BOLD}${srv}${NC}${srv_tag}${remote:+  (remote ${rip}:${rport}${proto:+, ${proto}})}"
    echo "Tunnel:  tun0 ${tip:-no address}"
    echo "Uptime:  $(ovpn_uptime 2>/dev/null || echo unknown)"

    if geo=$(egress_geo); then
        gip=$(printf '%s' "$geo" | cut -f1)
        gcity=$(printf '%s' "$geo" | cut -f2)
        gregion=$(printf '%s' "$geo" | cut -f3)
        gcc=$(printf '%s' "$geo" | cut -f4)
        geo_line="$gip"
        [ -n "$gcity" ] && geo_line="$geo_line — $gcity"
        [ -n "$gregion" ] && geo_line="$geo_line, $gregion"
        [ -n "$gcc" ] && geo_line="$geo_line, $gcc"
        echo "Egress:  ${geo_line}"
    fi
}

# Detailed status — the equivalent of wifi-manager's show_status().
show_status() {
    echo "*****************************************************"
    echo "VPN STATUS (NordVPN / OpenVPN)"
    echo "*****************************************************"
    echo ""

    quick_vpn_summary
    echo ""

    if ! is_connected; then
        echo "No tunnel is up: every connection leaves from this machine's own IP."
        echo "Connect with: vpn <country>   (e.g. vpn us, vpn mx — 'vpn list' shows codes)"
        return 0
    fi

    local remote rip rport proto ip mtu cfg pid
    remote=$(ovpn_remote 2>/dev/null)
    rip=${remote%% *}
    rport=${remote##* }
    proto=$(ovpn_proto 2>/dev/null)
    ip=$(tun0_ip)
    mtu=$(tun0_mtu)
    cfg=$(state_value config 2>/dev/null)
    pid=$(ovpn_pid 2>/dev/null)

    echo "----- Tunnel: tun0 -----"
    if is_vpn_alive; then
        echo -e "  State:   ${GREEN}UP${NC} (carries traffic)"
    else
        echo -e "  State:   ${YELLOW}UP but no traffic${NC} — recover with: vpn stop"
    fi
    echo "  IPv4:    ${ip:-no address}"
    [ -n "$mtu" ] && echo "  MTU:     $mtu"
    [ -n "$remote" ] && echo "  Remote:  ${rip}:${rport}${proto:+ ($proto)}"
    [ -n "$pid" ] && echo "  PID:     $pid"
    echo "  Uptime:  $(ovpn_uptime 2>/dev/null || echo unknown)  (since $(ovpn_started 2>/dev/null || echo unknown))"
    if [ -n "$cfg" ]; then
        echo "  Config:  $cfg"
    else
        echo "  Config:  $(ovpn_config_path 2>/dev/null || echo unknown) (temp copy; server matched by remote IP)"
    fi
    echo ""

    echo "Internet reachability check (ping 1.1.1.1)..."
    if is_vpn_alive; then
        echo -e "  Internet: ${GREEN}YES${NC} (reachable through the tunnel)"
    else
        echo -e "  Internet: ${YELLOW}NO${NC} (tunnel is up but nothing passes)"
    fi
}

# ── List ───────────────────────────────────────────────────────────────
list_countries() {
    if [ ! -f "$DNS_FILE" ]; then
        log_msg ERROR "country file not found: $DNS_FILE"
        return 1
    fi
    echo "*****************************************************"
    echo "AVAILABLE VPN COUNTRIES"
    echo "*****************************************************"
    echo ""
    while IFS=: read -r cc _; do
        cc=$(echo "$cc" | tr '[:upper:]' '[:lower:]')
        printf '  %-4s %s\n' "$cc" "$(country_name "$cc")"
    done < "$DNS_FILE"
}

print_usage() {
    echo "Usage: vpn                 status summary + interactive menu (X = exit)"
    echo "       vpn status          detailed status: country, server, endpoint, egress"
    echo "       vpn <country>       connect to country (e.g. us, uk, mx, jp)"
    echo "       vpn list            list available country codes"
    echo "       vpn stop            disconnect"
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

        echo -n "Connecting to ${BOLD}${server}${NC} ($(country_name "$cc"))... "

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
                write_state "$cc" "$server" "$config" "$(ovpn_remote)"
                echo ""
                echo -e "SUCCESS: ${GREEN}Connected${NC} to ${BOLD}$(country_name "$cc") (${cc})${NC} via ${server}."
                echo ""
                quick_vpn_summary
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
        echo -e "SUCCESS: ${RED}Disconnected${NC}. Traffic now goes out directly."
        return 0
    else
        log_msg ERROR "tun0 still up after kill — run: sudo pkill -9 openvpn"
        return 1
    fi
}

# ── Interactive menu (same flow as wifi-manager) ───────────────────────
interactive_menu() {
    while true; do
        echo ""
        quick_vpn_summary
        echo "*****************************************************"
        echo "VPN MANAGER (NORDVPN) - MAIN MENU"
        echo "*****************************************************"
        if is_connected; then
            echo "1. Show VPN status (country, server, endpoint, egress)"
            echo "2. Disconnect VPN"
            echo "X. Exit"
            echo "*****************************************************"
            read -p "Enter choice [1-2 or X]: " choice
            case "$choice" in
                1) show_status ;;
                2) echo ""; disconnect_vpn ;;
                x|X|exit|Exit|EXIT|q|Q|quit|2) echo ""; echo "Exiting VPN Manager."; return 0 ;;
                *) echo "Invalid choice. Please enter 1, 2 or X." ;;
            esac
        else
            echo "1. Connect by country code"
            echo "2. List available countries"
            echo "X. Exit"
            echo "*****************************************************"
            read -p "Enter choice [1-2 or X]: " choice
            case "$choice" in
                1)
                    echo ""
                    read -p "Enter 2-letter country code (e.g. us, uk, mx, jp): " cc
                    cc=$(echo "$cc" | tr '[:upper:]' '[:lower:]')
                    if [ ${#cc} -eq 2 ]; then
                        echo ""
                        connect_country "$cc"
                    else
                        echo "Invalid country code."
                    fi
                    ;;
                2) echo ""; list_countries ;;
                x|X|exit|Exit|EXIT|q|Q|quit|2) echo ""; echo "Exiting VPN Manager."; return 0 ;;
                *) echo "Invalid choice. Please enter 1, 2 or X." ;;
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
        --help|-h)
            print_usage
            exit 0
            ;;
        status|st|s)
            show_status
            exit 0
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
                    echo "VPN is connected by another user. Run 'vpn stop' as that user first."
                    exit 1
                fi
            fi
            if connect_country "$1"; then
                echo ""
                echo "Run 'vpn stop' to disconnect."
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
