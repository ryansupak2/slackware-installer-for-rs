#!/bin/sh
#
# dwl-start — Wayland/dwl session launcher
# Installed as /usr/local/bin/dwl-start
#
# Run from a text console.  Logs to ~/logs/dwl-YYYYMMDD-HHMMSS.log

set -e

LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOGFILE="$LOG_DIR/dwl-$(date +%Y%m%d-%H%M%S).log"

exec 1> >(tee -a "$LOGFILE") 2> >(tee -a "$LOGFILE" >&2)

echo "DWL session starting — $(date) — log: $LOGFILE"

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

# --- audio ---
echo "  · audio"
pkill -x pulseaudio 2>/dev/null || true
pkill -x pipewire-pulse 2>/dev/null || true
pkill -x pipewire-media-session 2>/dev/null || true
pkill -x pipewire 2>/dev/null || true
sleep 0.5
rm -f "$XDG_RUNTIME_DIR"/pipewire-0 "$XDG_RUNTIME_DIR"/pipewire-0.lock 2>/dev/null || true
rm -f "$XDG_RUNTIME_DIR"/pulse/native 2>/dev/null || true

pipewire &
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.1
    [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && break
    [ $i -eq 10 ] && { echo "ERROR: pipewire failed"; exit 1; }
done

pipewire-media-session &
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.2
    pactl info >/dev/null 2>&1 && break
    [ $i -eq 10 ] && { echo "ERROR: pipewire-media-session failed"; exit 1; }
done

pipewire-pulse &
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.1
    [ -S "$XDG_RUNTIME_DIR/pulse/native" ] && break
    [ $i -eq 10 ] && { echo "ERROR: pipewire-pulse failed"; exit 1; }
done

# Unmute hardware
amixer -c0 cset numid=9  87           >/dev/null 2>&1 || true
amixer -c0 cset numid=10 on           >/dev/null 2>&1 || true
amixer -c0 cset numid=3  87,87        >/dev/null 2>&1 || true
amixer -c0 cset numid=4  on,on        >/dev/null 2>&1 || true
amixer -c0 cset numid=1  0,0          >/dev/null 2>&1 || true
amixer -c0 cset numid=2  off,off      >/dev/null 2>&1 || true
for nid in 35 38 39 40 46 47; do
    amixer -c0 cset numid=$nid 32,32 >/dev/null 2>&1 || true
done

# --- net-watch ---
[ -x /usr/local/bin/net-watch ] && /usr/local/bin/net-watch >/dev/null 2>&1 &

# --- seatd ---
echo "  · cleaning seatd"
killall seatd 2>/dev/null || true
sudo pkill -x seatd 2>/dev/null || true
sleep 0.3
sudo rm -f /run/seatd.sock 2>/dev/null || true

# --- dwl + somebar ---
echo "  · launching dwl + somebar"
pkill -f dwl-status 2>/dev/null || true
sleep 0.3
rm -f "$XDG_RUNTIME_DIR"/somebar-* "$XDG_RUNTIME_DIR"/wayland-0 "$XDG_RUNTIME_DIR"/wayland-0.lock 2>/dev/null || true
udevadm trigger --subsystem-match=input --action=change 2>/dev/null || true
udevadm settle -t 3 2>/dev/null || true
sleep 0.5

dbus-run-session -- seatd-launch -- /bin/sh -c '
  /usr/local/bin/dwl 2>'"$XDG_RUNTIME_DIR"'/dwl.log |
  (
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
        sleep 0.1
        if [ -S '"$XDG_RUNTIME_DIR"'/wayland-0 ]; then break; fi
    done
    /usr/local/bin/dwl-status &
    if command -v foot >/dev/null 2>&1; then
        /usr/local/bin/somebar &
        sleep 0.5
        WAYLAND_DISPLAY=wayland-0 foot /usr/local/bin/neofetch-hold &
        wait
    else
        exec /usr/local/bin/somebar
    fi
  )
'

echo "DWL session ended — log: $LOGFILE"
printf '\033c'
