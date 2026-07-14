#!/bin/sh
#
# dwm-start — X11/dwm session launcher
# Run from a text console.  Logs to ~/logs/dwm-YYYYMMDD-HHMMSS.log
# All output mirrored to terminal so the log captures everything.

LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOGFILE="$LOG_DIR/dwm-$(date +%Y%m%d-%H%M%S).log"

# ── Output routing ───────────────────────────────────────────────
exec >>"$LOGFILE" 2>&1

echo "========================================"
echo "DWM session starting — $(date)"
echo "Log: $LOGFILE"
echo "========================================"

cleanup() {
    echo "  · cleaning up..."
    pkill -x voxd              2>/dev/null || true
    rm -f "$XDG_RUNTIME_DIR/vox_state" 2>/dev/null || true
    pkill -x pipewire-pulse       2>/dev/null || true
    pkill -x pipewire-media-session 2>/dev/null || true
    pkill -x wireplumber          2>/dev/null || true
    pkill -x pipewire             2>/dev/null || true
}
trap cleanup EXIT


# ── Runtime dir ───────────────────────────────────────────────
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if [ ! -d "$XDG_RUNTIME_DIR" ]; then
    sudo mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
    sudo chown $(whoami):$(whoami) "$XDG_RUNTIME_DIR" 2>/dev/null || true
    chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
fi
export PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native"

# ── Helper: start a daemon and wait for it ────────────────────
start_daemon() {
    local name="$1" binary="$2" check="$3" wait_s="$4" tries="$5"
    local i=0
    $binary &
    while [ $i -lt "$tries" ]; do
        sleep "$wait_s"
        eval "$check" 2>/dev/null && return 0
        i=$((i + 1))
    done
    echo "  WARNING: $name failed to start"
    return 1
}

# ── Audio (all optional — never block dwm) ────────────────────
echo "── audio ──"

pkill -x pulseaudio             2>/dev/null || true
pkill -x pipewire-pulse          2>/dev/null || true
pkill -x pipewire-media-session  2>/dev/null || true
pkill -x wireplumber             2>/dev/null || true
pkill -x pipewire                2>/dev/null || true
sleep 0.5

rm -f  "$XDG_RUNTIME_DIR/pipewire-0" "$XDG_RUNTIME_DIR/pipewire-0.lock" 2>/dev/null || true
rm -rf "$XDG_RUNTIME_DIR/pulse" 2>/dev/null || true

echo "  pipewire..."
start_daemon "pipewire"             pipewire \
    '[ -S "$XDG_RUNTIME_DIR/pipewire-0" ]' 0.1 10 || true

echo "  pipewire-media-session..."
start_daemon "pipewire-media-session" pipewire-media-session \
    'pgrep -f pipewire-media-session >/dev/null' 0.2 10 || true

echo "  pipewire-pulse..."
start_daemon "pipewire-pulse"      pipewire-pulse \
    '[ -S "$XDG_RUNTIME_DIR/pulse/native" ]' 0.1 10 || true

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

# ── X11 / dwm ─────────────────────────────────────────────────
echo "── dwm + st ──"

pkill -f dwm-status 2>/dev/null || true
sleep 0.3

# Generate a minimal xinitrc on the fly so dwm-start is self-contained.
# Keyboard backlight: set to 50% at X session start.
XINITRC="/tmp/xinitrc-dwm-$$"
cat > "$XINITRC" << 'XEOF'
#!/bin/sh

# Keyboard backlight to 50%
if [ -f /sys/class/leds/tpacpi::kbd_backlight/max_brightness ]; then
    max=$(cat /sys/class/leds/tpacpi::kbd_backlight/max_brightness 2>/dev/null || echo 1)
    half=$((max / 2))
    echo "$half" > /sys/class/leds/tpacpi::kbd_backlight/brightness 2>/dev/null || true
fi

# Caps Lock → Super (matches dwl's xkb caps:super)
xmodmap -e "clear lock" 2>/dev/null || true
xmodmap -e "keysym Caps_Lock = Super_L" 2>/dev/null || true
xmodmap -e "add mod4 = Super_L" 2>/dev/null || true

# dbus session (for notifications, etc.)
eval $(dbus-launch --sh-syntax) 2>/dev/null || true

# Status bar content generator (battery, vpn, time) — also initializes hide mode
/usr/local/bin/dwm-status &

# Network watcher (idempotent)
/usr/local/bin/net-watch &

# First terminal: neofetch runs via bashrc DWL_FIRST_TERMINAL hook
export DWL_FIRST_TERMINAL=1
st &

# Start dwm
exec dwm
XEOF
chmod +x "$XINITRC"

# Launch dwm via startx with our generated xinitrc
startx "$XINITRC"

# Cleanup generated xinitrc
rm -f "$XINITRC" 2>/dev/null || true

echo ""
echo "DWM session ended — $(date)"
echo "════════════════════════════════════════"
