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

echo "================================================================"
echo "DWL-START LAUNCH - $(date)"
echo "Log: $LOGFILE"
echo "================================================================"

echo "[1] Setting XDG_RUNTIME_DIR"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
echo "    XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"

echo "[2] Starting audio (PipeWire or PulseAudio)"
if command -v pipewire >/dev/null 2>&1; then
    pkill -x pipewire-pulse 2>/dev/null || true
    pkill -x wireplumber 2>/dev/null || true
    pkill -x pipewire 2>/dev/null || true
    sleep 0.5
    rm -f "$XDG_RUNTIME_DIR"/pipewire-0 "$XDG_RUNTIME_DIR"/pipewire-0.lock 2>/dev/null || true
    rm -f "$XDG_RUNTIME_DIR"/pulse/native 2>/dev/null || true
    pipewire 2>/dev/null &
    while [ ! -S "$XDG_RUNTIME_DIR/pipewire-0" ]; do sleep 0.2; done
    wireplumber 2>/dev/null &
    while ! wpctl status 2>/dev/null >/dev/null; do sleep 0.5; done
    pipewire-pulse 2>/dev/null &
    while [ ! -S "$XDG_RUNTIME_DIR/pulse/native" ]; do sleep 0.2; done
    # Set built-in microphone as default capture source
    MIC_ID=$(wpctl status 2>/dev/null | grep "Built-in Microphone" | awk '{for(i=1;i<=NF;i++) if($i~/^[0-9]+\\.$/) {sub(/\\./,"",$i); print $i; exit}}')
    [ -n "$MIC_ID" ] && wpctl set-default "$MIC_ID" 2>/dev/null
    wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0 2>/dev/null
    wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 1.0 2>/dev/null
    wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0 2>/dev/null
else
    echo "    PipeWire not found — using system PulseAudio."
fi

# Unmute hardware (SOF driver re-mutes on PCM open) — always run
amixer -c0 cset numid=9  87           >/dev/null 2>&1 || true  # Master
amixer -c0 cset numid=10 on           >/dev/null 2>&1 || true
amixer -c0 cset numid=3  87,87        >/dev/null 2>&1 || true  # Speaker
amixer -c0 cset numid=4  on,on        >/dev/null 2>&1 || true
amixer -c0 cset numid=1  0,0          >/dev/null 2>&1 || true  # Headphone
amixer -c0 cset numid=2  off,off      >/dev/null 2>&1 || true
for nid in 35 38 39 40 46 47; do
    amixer -c0 cset numid=$nid 32,32 >/dev/null 2>&1 || true
done
fi

echo "[3] Starting net-watch (background)"
if [ -x /usr/local/bin/net-watch ]; then
    /usr/local/bin/net-watch >/dev/null 2>&1 &
fi

echo "[4] Cleaning seatd socket (stop system service, kill seatd, remove stale socket)"
killall seatd 2>/dev/null || true
sudo pkill -x seatd 2>/dev/null || true
sleep 0.3
sudo rm -f /run/seatd.sock 2>/dev/null || true
echo "    seatd socket cleaned"

echo "[5] Launching dwl + somebar + services via seatd-launch"
# Kill orphaned dwl-status processes from prior sessions
# (they write to the FIFO path after somebar cleans it up, creating a
#  regular file that blocks the next session's FIFO creation)
pkill -f dwl-status 2>/dev/null || true
sleep 0.3
# Remove any stale somebar/wayland files from prior crashed sessions
rm -f "$XDG_RUNTIME_DIR"/somebar-* "$XDG_RUNTIME_DIR"/wayland-0 "$XDG_RUNTIME_DIR"/wayland-0.lock 2>/dev/null || true
# Ensure input devices are tagged (required for libinput/wlroots)
udevadm trigger --subsystem-match=input --action=change 2>/dev/null || true
udevadm settle -t 3 2>/dev/null || true
sleep 0.5
dbus-run-session -- seatd-launch -- /bin/sh -c '
  /usr/local/bin/dwl 2>'"$XDG_RUNTIME_DIR"'/dwl.log |
  (
    while [ ! -S '"$XDG_RUNTIME_DIR"'/wayland-0 ]; do sleep 0.1; done
    if command -v foot >/dev/null 2>&1; then
        WAYLAND_DISPLAY=wayland-0 foot /usr/local/bin/neofetch-hold 2>/dev/null &
    fi
    /usr/local/bin/dwl-status &
    if command -v cliphist >/dev/null 2>&1 && command -v wl-paste >/dev/null 2>&1; then
      wl-paste --watch cliphist store 2>/dev/null &
    fi
    exec /usr/local/bin/somebar 2>/dev/null
  )
' || true
printf '\033c'
