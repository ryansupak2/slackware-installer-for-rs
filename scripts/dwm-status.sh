#!/bin/bash
#
# dwm-status.sh — status bar content generator for dwm
# Writes to xsetroot -name so dwm's built-in bar renders it.
# Logs to ~/logs/dwm-status-YYYYMMDD-HHMMSS.log

LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOGFILE="$LOG_DIR/dwm-status-$(date +%Y%m%d-%H%M%S).log"
exec >>"$LOGFILE" 2>&1

echo "dwm-status starting: $(date)"

# ── Helper: signal hide-mode bar reveal ─────────────────────
# Writes to a named pipe that dwm monitors for show/hide commands.
# If the pipe doesn't exist (dwm not started yet), silently ignore.
signal_bar_show() {
    local pipe="$XDG_RUNTIME_DIR/dwmbar-0"
    if [ -p "$pipe" ]; then
        echo "show all" > "$pipe" 2>/dev/null || true
    fi
}

# ── Battery ─────────────────────────────────────────────────
prev_capacity=""
bat_part() {
    local status capacity icon indicator
    status=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo 'Unknown')
    capacity=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo '0')
    icon="BAT"
    if [ "$status" = "Charging" ]; then
        indicator="+"
    else
        indicator=""
    fi
    local out="${icon}: ${capacity}%${indicator}"
    if [ "$capacity" -le 10 ] && [ "$status" = "Discharging" ]; then
        out="(Low Battery!) ${out}"
    fi
    # Signal bar on capacity change
    if [ "$capacity" != "$prev_capacity" ]; then
        prev_capacity="$capacity"
        signal_bar_show
    fi
    echo -n "${out} "
}

# ── VPN ──────────────────────────────────────────────────────
last_vpn_check=0
vpn_status=""
vpn_part() {
    local now
    now=$(date +%s)
    if [ $((now - last_vpn_check)) -ge 5 ]; then
        if /usr/local/bin/openvpn-checkconnectionstatus.sh 2>/dev/null | grep -q "1"; then
            vpn_status="[VPN] "
        else
            vpn_status=""
        fi
        last_vpn_check=$now
    fi
    echo -n "$vpn_status"
}

# ── WiFi ─────────────────────────────────────────────────────
wifi_part() {
    local wifi_status
    wifi_status=$(rfkill list wlan 2>/dev/null | grep -o "blocked: yes" | head -1 || echo "enabled")
    if [ "$wifi_status" = "blocked: yes" ]; then
        echo -n "[WiFi Off - use Fn+F8] "
    fi
}

# ── Net status ───────────────────────────────────────────────
net_part() {
    local net_file="/tmp/net_status_$(id -u)"
    if [ -f "$net_file" ]; then
        local st
        st=$(cat "$net_file" 2>/dev/null)
        if [ "$st" = "DOWN" ]; then
            echo -n "[No Internet] "
        fi
    fi
}

# ── Main loop ────────────────────────────────────────────────
prev_status=""
while true; do
    status="$(wifi_part)$(vpn_part)$(net_part)$(bat_part)| $(date +'%a, %d %b %Y | %T')"

    if [ "$status" != "$prev_status" ]; then
        xsetroot -name "$status" 2>/dev/null
        prev_status="$status"
        signal_bar_show
    fi

    sleep 0.1
done
