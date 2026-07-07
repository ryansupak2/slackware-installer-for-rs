#!/bin/bash
# vpn-suspend.sh — VPN suspend/resume handler.
# pre:  disconnect VPN, save state, notify user.
# post: reconnect VPN from saved state, notify user.
# Called from elogind system-sleep hook with "pre" or "post" as $1.

export PATH="/usr/sbin:/sbin:/usr/local/bin:$PATH"

LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/vpn-suspend-$(date +%Y%m%d-%H%M%S).log"
exec >>"$LOG" 2>&1

echo "=================================================="
echo "vpn-suspend starting ($1): $(date)"
echo "Log: $LOG"
echo "=================================================="

log_msg() {
    local level="$1"; shift
    local msg="$*"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg"
}

# Resolve the VPN user from /run/user/*/vpn_state
find_vpn_user() {
    for sf in /run/user/*/vpn_state; do
        [ -f "$sf" ] || continue
        local u
        u=$(stat -c '%U' "$sf" 2>/dev/null)
        [ -z "$u" ] && continue
        local uid
        uid=$(stat -c '%u' "$sf" 2>/dev/null)
        echo "$u" "$uid" "$sf"
        return 0
    done
    return 1
}

# Write a temporary status message to the user's dwl bar
notify_user() {
    local uid="$1" msg="$2" duration="${3:-4}"
    local runtime="/run/user/$uid"
    [ -d "$runtime" ] || return 1
    echo "$msg" > "$runtime/status_msg" 2>/dev/null || true
    echo $(($(date +%s) + duration)) > "$runtime/status_end" 2>/dev/null || true
}

# --- PRE-SUSPEND: disconnect VPN ---
if [ "$1" = "pre" ]; then
    log_msg INFO "pre-suspend: checking for active VPN"

    if ! ip link show tun0 2>/dev/null | grep -q '<.*UP.*>'; then
        log_msg INFO "tun0 not UP — no VPN to disconnect"
        exit 0
    fi

    log_msg INFO "tun0 is UP — disconnecting VPN before suspend"

    # Restore IPv6 on non-tun interfaces
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -vE '^lo$|^tun'); do
        sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=0" >/dev/null 2>&1
    done

    # Kill openvpn
    pkill openvpn 2>/dev/null || true
    sleep 1
    pkill -9 openvpn 2>/dev/null || true
    sleep 0.5

    # Bring down tun0 if it survived
    if ip link show tun0 2>/dev/null | grep -q '<.*UP.*>'; then
        ip link set tun0 down 2>/dev/null || true
    fi

    log_msg INFO "VPN disconnected for suspend"

    # Notify the user (find user from .vpn-state which survives the kill)
    user_info=$(find_vpn_user)
    user_info=$(find_vpn_user)
    if [ -n "$user_info" ]; then
    read -r user uid sf <<< "$user_info"
        notify_user "$uid" "VPN paused for sleep" 4
        log_msg INFO "notified user '$user' (uid=$uid)"
    fi

    exit 0
fi

# --- POST-RESUME: reconnect VPN ---
if [ "$1" = "post" ]; then
    log_msg INFO "post-resume: checking for VPN to restore"

    user_info=$(find_vpn_user)
    user_info=$(find_vpn_user)
    if [ -z "$user_info" ]; then
        log_msg INFO "no vpn_state file found — nothing to restore"
        exit 0
    fi

    read -r user uid sf <<< "$user_info"
    cc=$(cat "$sf" 2>/dev/null)
    if [ -z "$cc" ]; then
        log_msg WARN "empty .vpn-state — nothing to restore"
        exit 0
    fi

    log_msg INFO "restoring VPN for user '$user' to country '$cc'"
    notify_user "$uid" "VPN reconnecting..." 5
    su - "$user" -c "/usr/local/bin/vpn $cc" &
    log_msg INFO "VPN reconnect initiated (PID: $!)"

    echo "=================================================="
    echo "vpn-suspend completed: $(date)"
    echo "=================================================="
    exit 0
fi

log_msg ERROR "unknown argument: $1 (expected pre or post)"
exit 1
