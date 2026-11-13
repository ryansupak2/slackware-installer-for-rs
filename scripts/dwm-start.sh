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

# Runtime dir. A real login (agetty/login + elogind) already creates
# /run/user/<uid> for the user, so no privilege is needed. Only an X start
# outside a logind session (e.g. from cron/ssh) needs it created, and that
# must not hang on a sudo password prompt: use -n, then fall back to a
# private /tmp dir instead of pointing every helper at a missing path.
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if [ ! -d "$XDG_RUNTIME_DIR" ]; then
    sudo -n mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
    sudo -n chown "$(id -un):$(id -gn)" "$XDG_RUNTIME_DIR" 2>/dev/null || true
fi
if [ ! -d "$XDG_RUNTIME_DIR" ]; then
    XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
    mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
    chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
fi
export XDG_RUNTIME_DIR
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
# Power policy for the current power source + wake restrictions (steps/power.sh)
/usr/local/bin/power boot 2>/dev/null || true

# Power button: hold-to-shut-down daemon. rc.local starts it at boot (outside
# any session) and it ignores SIGTERM, but if it is missing — rc.local not
# executable, killed by hand — every X start puts it back. Without this the
# 0.1 s hold count silently disappears from the bar.
[ -x /usr/local/bin/powerkey-hold-start ] && /usr/local/bin/powerkey-hold-start
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

# ── Mod keys: Caps Lock AND the Copilot key both act as Mod (Super/mod4) ──
# The map itself lives in /usr/local/bin/keyboard-mod-map (installed by
# steps/copilot-mod.sh) and is only CALLED here: the xinitrc is generated once
# per dwm-start and cached in /tmp, so a map written into this heredoc would be
# the old one for any session started from an older copy of this script — the
# reason the Copilot/Caps mapping vanished after an X restart. See that file
# for the keycodes and why the Copilot key's firmware Shift has to be dropped.
[ -x /usr/local/bin/keyboard-mod-map ] && /usr/local/bin/keyboard-mod-map

# Keyboard repeat rate
xset r rate 250 34 2>/dev/null || true

# Screen blanking / DPMS from the power policy (/var/lib/power/state).
# Applied on every X start so an X exit/restart cannot lose it.
power_blank=5
[ -r /var/lib/power/state ] && . /var/lib/power/state 2>/dev/null
[ -n "${BLANK_MINUTES:-}" ] && power_blank=$BLANK_MINUTES
if [ "$power_blank" -gt 0 ] 2>/dev/null; then
    xset s $((power_blank * 60)) $((power_blank * 60)) 2>/dev/null || true
    xset +dpms 2>/dev/null || true
    xset dpms $((power_blank * 60)) $((power_blank * 120)) $((power_blank * 240)) 2>/dev/null || true
else
    xset s 0 0 2>/dev/null || true
    xset dpms 0 0 0 2>/dev/null || true
fi

# Lock shortly BEFORE the screen blanks (idle-lock.sh reads BLANK_MINUTES from
# /var/lib/power/state, which is the same value the DPMS timers above use). The
# lead time is what guarantees a waking display shows slock, never the desktop.
/usr/local/bin/idle-lock.sh &

# TrackPoint scroll sensitivity
xinput set-prop "Elan TrackPoint" "libinput Scrolling Factor" 3.0 2>/dev/null || true

# Desktop background — per user, never hardcoded here:
#   ~/.dwm-background  >  /etc/dwm/backgrounds.conf (user=, then default=)
# root stays signal red (#CC0000); rs is medium grey (#808080).
DWM_BG=""
[ -r "$HOME/.dwm-background" ] && DWM_BG=$(head -1 "$HOME/.dwm-background" | tr -d ' \t\r\n')
if [ -z "$DWM_BG" ] && [ -r /etc/dwm/backgrounds.conf ]; then
    DWM_BG=$(awk -F= -v u="$(id -un)" '
        { k=$1; v=$2; gsub(/[ \t]/, "", k); gsub(/[ \t]/, "", v) }
        k == u         { print v; found=1; exit }
        k == "default" { d=v }
        END            { if (!found && d != "") print d }
    ' /etc/dwm/backgrounds.conf)
fi
[ -n "$DWM_BG" ] || DWM_BG="#808080"
xsetroot -solid "$DWM_BG" 2>/dev/null || true

# dbus session
eval $(dbus-launch --sh-syntax) 2>/dev/null || true

# Clipboard: mirror PRIMARY <-> CLIPBOARD and keep the last value after the
# owning app exits (autocutsel, installed by steps/clipboard.sh). Without it,
# a mouse selection in st only lands in PRIMARY, which Chrome's Ctrl+V does
# not read. Idempotent per user; output goes to this session log.
[ -x /usr/local/bin/clipboard-ensure ] && /usr/local/bin/clipboard-ensure


# Status bar + network watcher
/usr/local/bin/dwm-status &
/usr/local/bin/net-watch &

# Copilot key: drop the Shift its firmware sends with the key, so holding it is
# holding Mod. RECORD-based, starts nothing else (steps/copilot-mod.sh).
[ -x /usr/local/bin/copilot-mod ] && /usr/local/bin/copilot-mod &

# First terminal
DWL_FIRST_TERMINAL=1 st-logged &

cleanup() {
    echo "[dwm-start] X session ending — cleaning up..."
    pkill -f '/usr/local/bin/idle-lock.sh' 2>/dev/null || true
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
