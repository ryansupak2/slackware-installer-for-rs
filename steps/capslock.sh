#!/bin/bash
# steps/capslock.sh - /usr/local/bin/capslock: switch the X Caps Lock state
#
# Why this exists: the Caps Lock key is not a Caps Lock key on this machine.
# keycode 66 is mapped to Super_L (it is the dwm Mod key together with the
# Copilot key), and Fn never reaches software — the AT keyboard does not
# advertise KEY_FN and an evdev capture of a real Fn+CapsLock press produced no
# event — so the lock cannot be reached from any key or chord. The lock *state*
# still exists in the X server, so a command drives it (see
# scripts/keyboard-mod-map.sh and sources/capslock/capslock.c).
#
#   capslock          toggle           -> "Capslock On" / "Capslock Off"
#   capslock on|off   set explicitly
#   capslock --help
#
# Idempotent: rebuilds only when the source changed, installs only on a
# difference.
#
# Usage:
#   REPO_DIR=$PWD bash steps/capslock.sh          # build + install
#   REPO_DIR=$PWD bash steps/capslock.sh remove   # uninstall

REPO_DIR="${REPO_DIR:-/root/Development/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

ACTION="${1:-install}"
SRC="$REPO_DIR/sources/capslock/capslock.c"
BUILD=/var/cache/capslock
DEST=/usr/local/bin/capslock

echo "*****************************************************"
echo "CAPSLOCK COMMAND — $ACTION"
echo "*****************************************************"

ok=true
note() { echo "  $*"; }

if [ "$ACTION" = "remove" ]; then
    rm -f "$DEST" && note "removed $DEST"
    note "the current lock state stays as it is; nothing else uses this command"
    echo "SUCCESS: capslock command removed."
    exit 0
fi

# --- 1. build ---------------------------------------------------------------
[ -f "$SRC" ] || { echo "ERROR: $SRC missing"; exit 1; }
if [ ! -f /usr/include/X11/XKBlib.h ]; then
    install_pkg libX11 2>/dev/null || note "WARNING: libX11 headers not found"
fi
mkdir -p "$BUILD"
if [ -f "$DEST" ] && [ "$DEST" -nt "$SRC" ]; then
    note "$DEST already newer than the source"
else
    if gcc -O2 -Wall -Wextra -o "$BUILD/capslock" "$SRC" -lX11; then
        install -Dm 755 "$BUILD/capslock" "$DEST" && note "built + installed $DEST"
    else
        echo "ERROR: build failed"; exit 1
    fi
fi

# --- 2. show it works without changing the state ----------------------------
if "$DEST" --help >/dev/null 2>&1; then
    note "--help works"
else
    note "ERROR: $DEST --help failed"
    ok=false
fi

# Read-only state report (xset q prints the LED mask; no toggle involved).
led=$(xset q 2>/dev/null | sed -n 's/.*LED mask: *//p')
note "current lock : ${led:+LED mask $led}${led:-unknown (no X display?)}"
note "usage        : capslock | capslock on | capslock off | capslock --help"

if $ok; then
    echo "SUCCESS: 'capslock' toggles the X Caps Lock state (on/off/--help too)."
    exit 0
else
    echo "ERROR: capslock setup incomplete (see messages above)."
    exit 1
fi
