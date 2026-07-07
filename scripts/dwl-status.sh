#!/bin/sh
#
# dwl-status — continuous status bar text for dwl+somebar
# Writes "status <text>" lines to somebar's FIFO.
#
# Source shared temp-msg helper
if [ -f /usr/local/bin/temp-msg.sh ]; then
    . /usr/local/bin/temp-msg.sh
fi
HIDE_MODE_FILE="$XDG_RUNTIME_DIR/hide_mode"
FIFO="${XDG_RUNTIME_DIR}/somebar-0"
LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/dwl-status-$(date +%Y%m%d-%H%M%S).log"
exec >>"$LOG" 2>&1

# Wait for somebar to create its FIFO
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    sleep 0.1
    [ -p "$FIFO" ] && break
done
if [ ! -p "$FIFO" ]; then echo "$(date): FATAL - somebar FIFO never appeared" >&2; exit 1; fi
echo "$(date): FIFO=$FIFO" >&2

# Hide Mode initialization — default ON at session start
touch "$HIDE_MODE_FILE"
echo "hidemode on" > "$FIFO" 2>/dev/null
# Briefly show the bar with the hide mode message, then hide after 3s
set_temp_msg "(Hide Mode On [Mod+H])"
echo "show all" > "$FIFO" 2>/dev/null
next_log=0
next_ping=0
net_status="DOWN"
prev_kbd_brightness=$(cat /sys/class/leds/tpacpi::kbd_backlight/brightness 2>/dev/null || echo 0)
prev_signal=""
prev_msg_active=0
prev_msg=""
prev_online=""

while true; do
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
        bat_part="BAT:+${capacity}%"
    else
        bat_part="BAT: ${capacity}%"
    fi
    if [ "$capacity" -le 10 ] && [ "$status" = "Discharging" ]; then
        bat_part="(Low Battery!) ${bat_part}"
        # Low Battery forces hide mode off
        if [ -f "$HIDE_MODE_FILE" ]; then
            echo "$(date): LOW-BATTERY: capacity=$capacity% status=$status — forcing hide mode OFF" >&2
            rm -f "$HIDE_MODE_FILE"
            echo "hidemode off" > "$FIFO" 2>/dev/null
        fi
    fi

    now=$(date +%s)

    # Keyboard brightness temporary message
    current_kbd=$(cat /sys/class/leds/tpacpi::kbd_backlight/brightness 2>/dev/null || echo 0)
    if [ "$current_kbd" != "$prev_kbd_brightness" ]; then
        max=$(cat /sys/class/leds/tpacpi::kbd_backlight/max_brightness 2>/dev/null || echo 1)
        percent=$((current_kbd * 100 / max))
        set_temp_msg "Keyboard Brightness: $percent%"
        prev_kbd_brightness=$current_kbd
    fi
    # VNC detection (wayvnc process — screen sharing)
    if [ $((now - last_vnc_check)) -ge 1 ]; then
        if pgrep wayvnc >/dev/null 2>&1; then
            # Check for active viewer connections on VNC (5900) or RDP (3389)
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

    # VPN detection (tun0)
    if [ $((now - last_vpn_check)) -ge 1 ]; then
        if /usr/sbin/ip link show tun0 2>/dev/null | grep -q '<.*UP.*>'; then
            vpn_status="[VPN] "
        else
            vpn_status=""
        fi
        last_vpn_check=$now
    fi

    # VOX voice dictation state (Mod+V toggle)
    vox_file="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vox_state"
    if [ -f "$vox_file" ]; then
        case "$(cat "$vox_file" 2>/dev/null)" in
            loading)   vox_badge="[VOX Loading...] " ;;
            recording) vox_badge="[VOX] " ;;
            *)         vox_badge="[VOX] " ;;
        esac
    else
        vox_badge=""
    fi

    # Ping check (every 5s, backgrounded — never blocks the loop)
    if [ $((now - next_ping)) -ge 0 ]; then
        ( ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && echo UP || echo DOWN ) > "/tmp/dwl-ping-$(id -u).tmp" 2>/dev/null && mv "/tmp/dwl-ping-$(id -u).tmp" "/tmp/dwl-ping-$(id -u)" &
        next_ping=$((now + 5))
    fi
    net_status=$(cat "/tmp/dwl-ping-$(id -u)" 2>/dev/null || echo "DOWN")
    no_internet_prefix=""
    if [ "$net_status" != "UP" ]; then
        no_internet_prefix="[No Internet] "
    fi

    # Build status line
    full_line="${vox_badge}${vnc_status}${vpn_status}${no_internet_prefix}${bat_part} | $(date +'%a, %d %b %Y | %T')"

    # Build a "signal" line for change detection (strips clock and BAT % digits)
    bat_signal=$(echo "$bat_part" | sed 's/[0-9]\+%/%/g' | sed 's/BAT:+/BAT:/')
    signal_line="${vox_badge}${vnc_status}${vpn_status}${no_internet_prefix}${bat_signal}"

    hide_mode_on=0
    [ -f "$HIDE_MODE_FILE" ] && hide_mode_on=1

    # Temporary message overrides normal status
    msg_active=0
    msg_active=0
    msg=""
    if [ -f "$XDG_RUNTIME_DIR/status_msg" ] && [ "$now" -lt $(cat "$XDG_RUNTIME_DIR/status_end" 2>/dev/null || echo 0) ]; then
        msg=$(cat "$XDG_RUNTIME_DIR/status_msg")
        line="${vnc_status}${vpn_status}${msg} | $(date +'%T')"
        msg_active=1
    else
        rm -f "$XDG_RUNTIME_DIR/status_msg" "$XDG_RUNTIME_DIR/status_end" 2>/dev/null || true
        line="$full_line"
    fi
    # When a temporary message appears while in hide mode, show the bar so the
    # user sees the message (matching the standard Volume/Brightness behavior)
    # When a temporary message appears or changes while in hide mode, show the bar
    if [ "$hide_mode_on" = 1 ] && [ "$msg_active" = 1 ]; then
        if [ "$prev_msg_active" = 0 ] || [ "$msg" != "$prev_msg" ]; then
            echo "$(date): TEMP-MSG show: msg='$msg'" >&2
            echo "show all" > "$FIFO" 2>/dev/null
        fi
    fi
    # When a temporary message expires, just log (somebar's timer handles re-hide)
    if [ "$hide_mode_on" = 1 ] && [ "$msg_active" = 0 ] && [ "$prev_msg_active" = 1 ]; then
        echo "$(date): TEMP-MSG hide: msg expired" >&2
    fi

    # Hide Mode: detect meaningful status changes and briefly show the bar
    if [ "$hide_mode_on" = 1 ] && [ "$signal_line" != "$prev_signal" ] && [ -n "$prev_signal" ]; then
        echo "$(date): SIGNAL show: prev='${prev_signal}' new='${signal_line}'" >&2
        echo "show all" > "$FIFO" 2>/dev/null
        # auto-hide handled by somebar's autoShowUntil timer
    fi
    prev_signal="$signal_line"
    prev_msg_active=$msg_active
    prev_msg="$msg"

    # Detect physical charger plug/unplug (not battery charging toggling)
    online=0
    # Log raw power supply files for debugging
    ps_files=$(ls /sys/class/power_supply/*/online 2>/dev/null)
    ps_values=$(cat /sys/class/power_supply/*/online 2>/dev/null | tr '\n' ' ')
    if [ -n "$ps_files" ]; then
        if grep -q '^1$' /sys/class/power_supply/*/online 2>/dev/null; then online=1; fi
        # Log on every change to help diagnose spurious unhides
        if [ "$online" != "$prev_online" ]; then
            echo "$(date): POWER online changed: prev='$prev_online' new='$online' | files=$ps_files | values=[$ps_values] | hide_mode=$hide_mode_on | status=$status cap=$capacity%" >&2
        fi
    fi
    if [ "$hide_mode_on" = 1 ] && [ "$online" != "$prev_online" ] && [ -n "$prev_online" ]; then
        echo "$(date): POWER show: prev_online=$prev_online online=$online (AC plug/unplug detected)" >&2
        echo "show all" > "$FIFO" 2>/dev/null
        # auto-hide handled by somebar's autoShowUntil timer
    fi
    prev_online="$online"

    if [ ! -p "$FIFO" ]; then
        echo "$(date): FIFO removed — session ended"
        break
    fi
    if echo "status ${line}" > "$FIFO" 2>/dev/null; then
        if [ $next_log -le 0 ]; then
            echo "$(date): wrote: ${line}"
            next_log=60
        fi
    else
        echo "$(date): WRITE FAILED — session ended"
        break
    fi

    next_log=$((next_log - 1))
    sleep 0.1
done
