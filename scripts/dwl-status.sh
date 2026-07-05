#!/bin/sh
#
# dwl-status — continuous status bar text for dwl+somebar
# Writes "status <text>" lines to somebar's FIFO.

FIFO="${XDG_RUNTIME_DIR}/somebar-0"
LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/dwl-status-$(date +%Y%m%d-%H%M%S).log"
exec 2>>"$LOG"
echo "$(date): dwl-status started (PID $$)" >&2

# Wait for somebar to create its FIFO
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    sleep 0.1
    [ -p "$FIFO" ] && break
done
if [ ! -p "$FIFO" ]; then echo "$(date): FATAL - somebar FIFO never appeared" >&2; exit 1; fi
echo "$(date): FIFO=$FIFO" >&2

next_log=0
next_ping=0
net_status="DOWN"
prev_kbd_brightness=$(cat /sys/class/leds/tpacpi::kbd_backlight/brightness 2>/dev/null || echo 0)

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
    fi

    now=$(date +%s)

    # Keyboard brightness temporary message
    current_kbd=$(cat /sys/class/leds/tpacpi::kbd_backlight/brightness 2>/dev/null || echo 0)
    if [ "$current_kbd" != "$prev_kbd_brightness" ]; then
        max=$(cat /sys/class/leds/tpacpi::kbd_backlight/max_brightness 2>/dev/null || echo 1)
        percent=$((current_kbd * 100 / max))
        echo "Keyboard Brightness: $percent%" > /tmp/status_msg
        echo $((now + 3)) > /tmp/status_end
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
        if ip link show tun0 2>/dev/null | grep -q '<.*UP.*>'; then
            vpn_status="[VPN] "
        else
            vpn_status=""
        fi
        last_vpn_check=$now
    fi

    # Ping check (every 5s, direct, no external process)
    if [ $((now - next_ping)) -ge 0 ]; then
        if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
            net_status="UP"
        else
            net_status="DOWN"
        fi
        next_ping=$((now + 5))
    fi
    no_internet_prefix=""
    if [ "$net_status" != "UP" ]; then
        no_internet_prefix="[No Internet] "
    fi

    # Temporary keyboard brightness message overrides normal status
    if [ -f /tmp/status_msg ] && [ "$now" -lt $(cat /tmp/status_end 2>/dev/null || echo 0) ]; then
        msg=$(cat /tmp/status_msg)
        line="${vnc_status}${vpn_status}${msg} | $(date +'%T')"
    else
        rm -f /tmp/status_msg /tmp/status_end 2>/dev/null || true
        line="${vnc_status}${vpn_status}${no_internet_prefix}${bat_part} | $(date +'%a, %d %b %Y | %T')"
    fi

    if echo "status ${line}" > "$FIFO" 2>/dev/null; then
        if [ $next_log -le 0 ]; then
            echo "$(date): wrote: ${line}" >&2
            next_log=60
        fi
    else
        echo "$(date): WRITE FAILED" >&2
        next_log=0
    fi
    next_log=$((next_log - 1))

    sleep 0.1
done
