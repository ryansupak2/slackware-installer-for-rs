#!/bin/sh
# dwm-start — X11/dwm session launcher

LOG_DIR="/var/log/${USER:-root}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOGFILE="$LOG_DIR/dwm-$(date +%Y%m%d-%H%M%S).log"
exec >>"$LOGFILE" 2>&1

if [ -n "$DISPLAY" ]; then
    echo "ERROR: Already inside an X session (DISPLAY=$DISPLAY)." >&2
    exit 1
fi

echo "DWM session starting — $(date)"
echo "Log: $LOGFILE"

# Runtime dir
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if [ ! -d "$XDG_RUNTIME_DIR" ]; then
    sudo mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
    sudo chown $(whoami):$(whoami) "$XDG_RUNTIME_DIR" 2>/dev/null || true
    chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
fi
export PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native"

# ── Audio ──
echo "── audio ──"
pkill -x pulseaudio 2>/dev/null || true
pkill -x pipewire 2>/dev/null || true
pkill -x pipewire-media-session 2>/dev/null || true
pkill -x wireplumber 2>/dev/null || true
pkill -x pipewire-pulse 2>/dev/null || true
sleep 0.5
rm -f "$XDG_RUNTIME_DIR/pipewire-0" "$XDG_RUNTIME_DIR/pipewire-0.lock" 2>/dev/null || true
rm -rf "$XDG_RUNTIME_DIR/pulse" 2>/dev/null || true

echo "  pipewire..."
pipewire &
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.1
    [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && break
done

echo "  pipewire-media-session..."
pipewire-media-session &
sleep 0.2

echo "  pipewire-pulse..."
pipewire-pulse &
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.1
    [ -S "$XDG_RUNTIME_DIR/pulse/native" ] && break
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

# ── X11 / dwm ──
/usr/local/bin/wakeup-power-only 2>/dev/null || true
echo "── dwm + st ──"

pkill -f dwm-status 2>/dev/null || true
sleep 0.3

XINITRC="/tmp/xinitrc-dwm-$$"
cat > "$XINITRC" << 'XEOF'
#!/bin/sh

# Keyboard backlight to 50%
if [ -f /sys/class/leds/tpacpi::kbd_backlight/max_brightness ]; then
    max=$(cat /sys/class/leds/tpacpi::kbd_backlight/max_brightness 2>/dev/null || echo 1)
    half=$((max / 2))
    echo "$half" > /sys/class/leds/tpacpi::kbd_backlight/brightness 2>/dev/null || true
fi

# Caps Lock → Super
xmodmap -e "clear lock" 2>/dev/null || true
xmodmap -e "keysym Caps_Lock = Super_L" 2>/dev/null || true
xmodmap -e "add mod4 = Super_L" 2>/dev/null || true

# Keyboard repeat rate
xset r rate 250 34 2>/dev/null || true

# TrackPoint scroll sensitivity
xinput set-prop "Elan TrackPoint" "libinput Scrolling Factor" 3.0 2>/dev/null || true

# Desktop background — signal red for root
[ "$(whoami)" = "root" ] && xsetroot -solid "#CC0000" 2>/dev/null || true

# dbus session
eval $(dbus-launch --sh-syntax) 2>/dev/null || true

# Status bar + network watcher
/usr/local/bin/dwm-status &
/usr/local/bin/net-watch &

# First terminal
DWL_FIRST_TERMINAL=1 st-logged &

cleanup() {
    echo "[dwm-start] X session ending — cleaning up..."
    /usr/local/bin/vpn disconnect 2>/dev/null || true
    pkill -USR1 voxd 2>/dev/null || true
    echo "[dwm-start] cleanup complete"
}
trap cleanup EXIT

dwm
XEOF
chmod +x "$XINITRC"

startx "$XINITRC"
rm -f "$XINITRC" 2>/dev/null || true

echo "DWM session ended — $(date)"
