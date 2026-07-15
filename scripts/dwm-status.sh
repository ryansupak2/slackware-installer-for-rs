#!/bin/bash
#
# dwm-status.sh — status bar content generator for dwm
# Writes to xsetroot -name so dwm's built-in bar renders it.
# Logs to /var/log/<user>-dwm-status-YYYYMMDD-HHMMSS.log

LOG_DIR="/var/log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOGFILE="$LOG_DIR/${USER:-root}-dwm-status-$(date +%Y%m%d-%H%M%S).log"
exec >>"$LOGFILE" 2>&1

echo "dwm-status starting: $(date)"

FIFO="$XDG_RUNTIME_DIR/dwmbar-0"
HIDE_MODE_FILE="$XDG_RUNTIME_DIR/hide_mode"

# Source shared temp-msg helper
if [ -f /usr/local/bin/temp-msg.sh ]; then
    . /usr/local/bin/temp-msg.sh
fi

# Wait for dwm to create the FIFO
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    sleep 0.1
    [ -p "$FIFO" ] && break
done
if [ ! -p "$FIFO" ]; then
    echo "$(date): ERROR - dwmbar FIFO not present after 3s wait, hide mode init SKIPPED" >&2
else
    echo "$(date): FIFO=$FIFO  hidemode_file=$HIDE_MODE_FILE" >&2
    # Hide Mode initialization — default ON at session start
    touch "$HIDE_MODE_FILE"
    echo "hidemode on" > "$FIFO" 2>/dev/null
    echo "$(date): hide mode initialized ON, hidemode on -> FIFO" >&2
    # Set temp message — main loop will trigger the initial bar show
    set_temp_msg "(Hide Mode On [Mod+H])" 4
fi

# ── Helper: signal hide-mode bar reveal ─────────────────────
# Writes to a named pipe that dwm monitors for show/hide commands.
signal_bar_show() {
    local pipe="$XDG_RUNTIME_DIR/dwmbar-0"
    if [ -p "$pipe" ]; then
        echo "show all" > "$pipe" 2>/dev/null || true
    fi
}

# ── VOX voice dictation state ─────────────────────────────────
vox_part() {
    local vox_file="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vox_state"
    if [ -f "$vox_file" ]; then
        case "$(cat "$vox_file" 2>/dev/null)" in
            loading)         echo -n '[VOX Loading...] ' ;;
            recording)       echo -n '[VOX] ' ;;
            recording+dump)  echo -n '[VOX (recording...)] ' ;;
            *)               echo -n '[VOX] ' ;;
        esac
    fi
}

# ── VNC detection ─────────────────────────────────────────────
last_vnc_check=0
vnc_status=""
vnc_part() {
    local now
    now=$(date +%s)
    if [ $((now - last_vnc_check)) -ge 1 ]; then
        if pgrep wayvnc >/dev/null 2>&1; then
            if ss -tn state established sport = :5900 2>/dev/null | tail -n +2 | grep -q . || \
               ss -tn state established sport = :3389 2>/dev/null | tail -n +2 | grep -q .; then
                vnc_status="[Sharing Screen!] "
            else
                vnc_status="[VNC] "
            fi
        else
            vnc_status=""
        fi
        last_vnc_check=$now
    fi
    echo -n "$vnc_status"
}

# ── Battery ─────────────────────────────────────────────────
prev_capacity=""
prev_bat_status=""
bat_part() {
    local status capacity on_ac
    status=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo 'Unknown')
    capacity=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo '0')
    on_ac=0
    if grep -q '^1$' /sys/class/power_supply/*/online 2>/dev/null; then on_ac=1; fi
    if [ "$on_ac" = 0 ]; then
        case "$status" in
            Charging) on_ac=1 ;;
        esac
    fi
    if [ "$on_ac" = 1 ]; then
        local bat_out="BAT:+${capacity}%"
    else
        local bat_out="BAT: ${capacity}%"
    fi
    if [ "$capacity" -le 10 ] && [ "$status" = "Discharging" ]; then
        bat_out="(Low Battery!) ${bat_out}"
        # Low Battery forces hide mode off
        if [ -f "$HIDE_MODE_FILE" ]; then
            echo "$(date): LOW-BATTERY: capacity=$capacity% status=$status — forcing hide mode OFF" >&2
            rm -f "$HIDE_MODE_FILE"
            echo "hidemode off" > "$FIFO" 2>/dev/null
        fi
    fi
    # Signal bar only on charging status transitions (not routine capacity changes)
    if [ "$status" != "$prev_bat_status" ]; then
        if [ -n "$prev_bat_status" ]; then
            echo "$(date): BAT status change: prev='$prev_bat_status' new='$status' on_ac=$on_ac" >&2
            signal_bar_show
        fi
        prev_bat_status="$status"
    fi
    prev_capacity="$capacity"
    echo -n "${bat_out} "
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

# ── Keyboard brightness temp messages ─────────────────────────
prev_kbd_brightness=$(cat /sys/class/leds/tpacpi::kbd_backlight/brightness 2>/dev/null || echo 0)

# ── Main loop ────────────────────────────────────────────────
prev_signal=""
prev_msg_active_val=0
prev_msg_val=""
while true; do
    # VOX badge
    vox_badge="$(vox_part)"

    # VNC badge
    vnc_badge="$(vnc_part)"

    # VPN badge
    vpn_badge="$(vpn_part)"

    # Network status
    net_badge="$(net_part)"

    # Battery status
    bat_badge="$(bat_part)"

    # Keyboard brightness temporary message
    current_kbd=$(cat /sys/class/leds/tpacpi::kbd_backlight/brightness 2>/dev/null || echo 0)
    if [ "$current_kbd" != "$prev_kbd_brightness" ]; then
        max=$(cat /sys/class/leds/tpacpi::kbd_backlight/max_brightness 2>/dev/null || echo 1)
        percent=$((current_kbd * 100 / max))
        type set_temp_msg >/dev/null 2>&1 && set_temp_msg "Keyboard Brightness: $percent%"
        prev_kbd_brightness=$current_kbd
    fi

    # Build status line
    now=$(date +%s)
    hide_mode_on=0
    [ -f "$HIDE_MODE_FILE" ] && hide_mode_on=1

    # Temp message overrides normal status
    msg_active=0
    msg=""
    if [ -f "$XDG_RUNTIME_DIR/status_msg" ] && [ "$now" -lt $(cat "$XDG_RUNTIME_DIR/status_end" 2>/dev/null || echo 0) ]; then
        msg=$(cat "$XDG_RUNTIME_DIR/status_msg")
        line="${msg} | $(date +'%T')"
        msg_active=1
    else
        rm -f "$XDG_RUNTIME_DIR/status_msg" "$XDG_RUNTIME_DIR/status_end" 2>/dev/null || true
        line="${vox_badge}${vnc_badge}${vpn_badge}${net_badge}${bat_badge}| $(date +'%a, %d %b %Y | %T')"
    fi

    # Build signal line for change detection (strips clock + battery digits)
    bat_signal=$(echo "$bat_badge" | sed 's/[0-9]\+%/%/g' | sed 's/BAT:+/BAT:/')
    signal_line="${vox_badge}${vnc_badge}${vpn_badge}${net_badge}${bat_signal}"

    # Temp message: when it appears or changes in hide mode, show bar
    if [ "$hide_mode_on" = 1 ] && [ "$msg_active" = 1 ]; then
        if [ -z "$prev_msg_active_val" ] || [ "$prev_msg_active_val" = 0 ] || [ "$msg" != "$prev_msg_val" ]; then
            echo "$(date): TEMP-MSG show: msg='$msg'" >&2
            signal_bar_show
        fi
    fi
    prev_msg_active_val=$msg_active
    prev_msg_val="$msg"

    # Hide Mode: detect meaningful status changes and briefly show bar
    if [ "$hide_mode_on" = 1 ] && [ "$signal_line" != "$prev_signal" ] && [ -n "$prev_signal" ]; then
        echo "$(date): SIGNAL change: prev='${prev_signal}' new='${signal_line}'" >&2
        signal_bar_show
    fi
    prev_signal="$signal_line"

    # Write to xsetroot if status changed
    # Write to xsetroot if status changed
    if [ "$line" != "$prev_status" ]; then
        xsetroot -name "$line" 2>/dev/null
        prev_status="$line"
        # Status text updated — xsetroot handles the bar redraw via dwm's
        # built-in PropertyNotify handler.  No FIFO signal needed here;
        # the specific change handlers above (battery, power, temp-msg,
        # signal) already call signal_bar_show when hide mode is on.
    fi

    sleep 0.1
done
