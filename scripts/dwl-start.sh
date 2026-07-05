#!/bin/sh
#
# dwl-start — Wayland/dwl session launcher
# Run from a text console.  Logs to ~/logs/dwl-YYYYMMDD-HHMMSS.log
#   -v, --verbose  Show output on terminal (default: log only)

LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOGFILE="$LOG_DIR/dwl-$(date +%Y%m%d-%H%M%S).log"

# ── Parse flags ──────────────────────────────────────────────────
VERBOSE=0
case "${1:-}" in
    -v|--verbose) VERBOSE=1 ;;
esac

# ── Output routing ───────────────────────────────────────────────
# Default (quiet): everything → log only (clean terminal)
# Verbose:         both → log + terminal
if [ "$VERBOSE" = 1 ]; then
    exec > >(tee -a "$LOGFILE") 2>&1
else
    exec >>"$LOGFILE" 2>&1
fi

echo "========================================"
echo "DWL session starting — $(date)"
echo "Log: $LOGFILE"
echo "========================================"

cleanup() {
    echo "  · cleaning up audio..."
    pkill -x pipewire-pulse       2>/dev/null || true
    pkill -x pipewire-media-session 2>/dev/null || true
    pkill -x wireplumber          2>/dev/null || true
    pkill -x pipewire             2>/dev/null || true
}
trap cleanup EXIT

# ── Runtime dir ───────────────────────────────────────────────
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
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

# ── Audio (all optional — never block dwl) ────────────────────
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

# ── Seatd ─────────────────────────────────────────────────────
echo "── seatd ──"
killall seatd 2>/dev/null || true
sudo pkill -x seatd 2>/dev/null || true
sleep 0.3
sudo rm -f /run/seatd.sock 2>/dev/null || true

# ── DWL ───────────────────────────────────────────────────────
echo "── dwl + somebar + foot ──"
pkill -f dwl-status 2>/dev/null || true
sleep 0.3
rm -f "$XDG_RUNTIME_DIR"/somebar-* "$XDG_RUNTIME_DIR"/wayland-0 "$XDG_RUNTIME_DIR"/wayland-0.lock 2>/dev/null || true
udevadm trigger --subsystem-match=input --action=change 2>/dev/null || true
udevadm settle -t 3 2>/dev/null || true
sleep 0.5

# Start dwl inside dbus+seatd session.  Stderr is explicitly merged
# into the logging stream so nothing leaks to the raw console device.
dbus-run-session -- seatd-launch -- /bin/sh -c '
exec 2>&1
  /usr/local/bin/dwl |
  (
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
        sleep 0.1
        if [ -S '"$XDG_RUNTIME_DIR"'/wayland-0 ]; then break; fi
    done
    /usr/local/bin/dwl-status &
    /usr/local/bin/somebar &
    WAYLAND_DISPLAY=wayland-0 foot -- bash -l &
    wait
  )
'

echo ""
echo "DWL session ended — $(date)"
# Show a visible divider so any errors above it are readable.
# (The terminal is not cleared — errors after dwl exit stay visible.)
echo "════════════════════════════════════════"
