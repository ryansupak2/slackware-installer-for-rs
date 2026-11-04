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
# Audio is owned by /usr/local/bin/pipewire-ensure (steps/pipewire.sh).
# It probes the session and, if clients cannot connect (which happens after
# exit/re-enter X: /run/user/<uid> is emptied when the logind session ends,
# so the daemons keep listening on inodes whose paths are gone), it resets
# the stack and verifies pactl again. Never start the daemons here directly:
# half-started stacks are what produced the stale-socket breakage.
if [ -x /usr/local/bin/pipewire-ensure ]; then
    /usr/local/bin/pipewire-ensure
else
    echo "  WARNING: pipewire-ensure missing — run steps/pipewire.sh"
    if ! pgrep -x pipewire >/dev/null 2>&1; then
        pipewire &
        wireplumber &
        sleep 0.5
        pipewire-pulse &
        sleep 0.5
    fi
fi

# Unmute hardware via /usr/local/bin/audio-mixer-fix (NAMED controls only).
# On SOF/SoundWire machines (Dell XPS 13: cs42l43 codec + CS35L56 amps) numids
# are assigned per card/driver and are nothing like the legacy HDA numids —
# the old 'numid=1 0,0 / numid=2 off,off' pair was really muting the internal
# speaker's Playback Switch/Volume at every session start.
if [ -x /usr/local/bin/audio-mixer-fix ]; then
    AUDIO_MIXER_QUIET=0 /usr/local/bin/audio-mixer-fix || true
else
    amixer -c0 sset 'Speaker' 76% unmute         >/dev/null 2>&1 || true
    amixer -c0 sset 'cs42l43 Speaker Digital' on >/dev/null 2>&1 || true
fi

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
    # Audio daemons are deliberately NOT killed and their sockets NOT removed.
    # Doing that is what used to break sound: the supervisors respawn the
    # daemons, but the rm -f left them listening on unlinked inodes, so every
    # client got ECONNREFUSED after re-entering X. /usr/local/bin/pipewire-ensure
    # at the next session start validates and repairs the session instead.
    echo "[dwm-start] cleanup complete (audio left running)"
}

dwm
XEOF
chmod +x "$XINITRC"

startx "$XINITRC"
rm -f "$XINITRC" 2>/dev/null || true

echo "DWM session ended — $(date)"
