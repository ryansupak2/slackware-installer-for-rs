#!/bin/bash
# steps/copilot-mod.sh - the Copilot key acts as Mod (Super), alone
#
# The key is keycode 201 (evdev KEY_F23). Its firmware presses Shift + Super in
# the same burst (the Microsoft keyboard spec), and xkeyboard-config maps that
# chord to XF86Assistant. dwm uses Mod4 (Super) as MODKEY, so:
#
#   * dwm-start maps keycode 201 to Super_L, so the key asserts Mod4 even on
#     firmware that sends no Super of its own;
#   * /usr/local/bin/copilot-mod (built here) drops the firmware's Shift with
#     XTest while the key is held. That must happen in the server's modifier
#     state, not in dwm: dwm grabs keys with exact masks, so a stray Shift turns
#     Mod+X into Mod+Shift+X (tag instead of view, quit for Mod+Shift+Q) and
#     bindings with no Shift sibling (Mod+Return, Mod+r, ...) never reach dwm.
#
# It watches with RECORD, so no key is grabbed and nothing is taken away from
# the focused client. Put together, holding Copilot is exactly holding Mod.
#
# Caps Lock is handled entirely by dwm-start's xmodmap (level 1 Super_L,
# level 2 Caps_Lock = Shift+CapsLock still locks; Fn never reaches software, the
# AT keyboard does not advertise KEY_FN).
#
# Idempotent: rebuilds only when the source changed, installs only when the
# binary differs, starts nothing twice (the daemon holds a flock on
# no pidfile: it lives exactly as long as its X server).
#
# Usage:
#   REPO_DIR=$PWD bash steps/copilot-mod.sh          # build + install + start
#   REPO_DIR=$PWD bash steps/copilot-mod.sh remove   # uninstall

REPO_DIR="${REPO_DIR:-/root/Development/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

ACTION="${1:-install}"
SRC="$REPO_DIR/sources/copilot-mod/copilot-mod.c"
BUILD=/var/cache/copilot-mod
DEST=/usr/local/bin/copilot-mod
LOGF="/var/log/${USER:-root}-copilot-mod.log"

echo "*****************************************************"
echo "COPILOT KEY AS MOD — $ACTION"
echo "*****************************************************"

ok=true
note() { echo "  $*"; }

# The daemon has no pidfile on purpose: it lives exactly as long as its X server
# (RECORD dies with the connection), and a lock left behind by a dead session
# used to refuse the next start. comm is "copilot-mod" (pgrep -x).
running_pid() {
    local pid
    pid=$(pgrep -x copilot-mod 2>/dev/null | head -1)
    [ -n "$pid" ] || return 1
    echo "$pid"
}

if [ "$ACTION" = "remove" ]; then
    if p=$(running_pid); then
        kill "$p" 2>/dev/null && note "stopped copilot-mod (pid $p)"
    fi
    rm -f "$DEST" && note "removed $DEST"
    rm -f /usr/local/bin/keyboard-mod-map && note "removed /usr/local/bin/keyboard-mod-map"
    note "the current keymap stays until X restarts; then the stock one is used"
    echo "SUCCESS: copilot-mod removed."
    exit 0
fi

# --- 1. build deps ----------------------------------------------------------
if [ ! -f /usr/include/X11/extensions/record.h ]; then
    install_pkg libXtst 2>/dev/null || note "WARNING: libXtst headers not found"
fi

# --- 2. build ---------------------------------------------------------------
[ -f "$SRC" ] || { echo "ERROR: $SRC missing"; exit 1; }
mkdir -p "$BUILD"
if [ -f "$DEST" ] && [ "$DEST" -nt "$SRC" ]; then
    note "$DEST already newer than the source"
else
    if gcc -O2 -Wall -Wextra -o "$BUILD/copilot-mod" "$SRC" -lX11 -lXtst; then
        install -Dm 755 "$BUILD/copilot-mod" "$DEST" && note "built + installed $DEST"
    else
        echo "ERROR: build failed"; exit 1
    fi
fi

# --- 3. the keymap side: one installed script, called at every X start -------
# It is a separate file because the xinitrc is generated once per dwm-start and
# cached in /tmp: a map written into that heredoc is stale for a session started
# from an older copy (how the mapping vanished after an X restart).
MAPSRC="$REPO_DIR/scripts/keyboard-mod-map.sh"
MAPDEST=/usr/local/bin/keyboard-mod-map
if [ -f "$MAPSRC" ]; then
    if [ -f "$MAPDEST" ] && cmp -s "$MAPSRC" "$MAPDEST"; then
        note "$MAPDEST already up to date"
    else
        install -Dm 755 "$MAPSRC" "$MAPDEST" && note "installed $MAPDEST"
    fi
fi
if grep -q 'keyboard-mod-map' "$REPO_DIR/scripts/dwm-start.sh"; then
    note "dwm-start calls it at every X start (keycode 66 Caps, 201 Copilot -> Mod)"
else
    note "WARNING: scripts/dwm-start.sh does not call keyboard-mod-map — reinstall it"
    ok=false
fi

# --- 4. start it now --------------------------------------------------------
# A running instance keeps the code it was started with, so a rebuilt binary
# only takes effect after a restart. Its SIGTERM handler releases a Synthetic
# Mod4 before exiting, so stopping it mid-hold cannot leave Mod stuck down.
if p=$(running_pid); then
    if [ "$DEST" -nt "/proc/$p" ]; then
        kill "$p" 2>/dev/null \
            && note "binary changed — restarted the running instance (pid $p)"
        sleep 0.3
    fi
fi
if p=$(running_pid); then
    note "already running:"
    ps -o pid=,etime=,args= -p "$p" | sed 's/^/    /'
else
    setsid "$DEST" >>"$LOGF" 2>&1 &
    sleep 1
    if p=$(running_pid); then
        note "started:"
        ps -o pid=,etime=,args= -p "$p" | sed 's/^/    /'
    else
        note "NOT running in this session (no DISPLAY, or not mapped yet?) —"
        note "dwm-start starts it at every X start; see $LOGF"
        tail -3 "$LOGF" 2>/dev/null | sed 's/^/    /'
    fi
fi

# --- 5. show the facts ------------------------------------------------------
note "keymap      : keycode 66 (Caps Lock) = Super_L only (Mod; caps lock is UNBOUND)"
note "keymap      : keycode 201 (Copilot)  = Super_L on both levels (Mod4)"
note "shift fix   : copilot-mod drops the firmware Shift while the key is held"
note "log         : $LOGF"

if $ok; then
    echo "SUCCESS: Caps Lock and Copilot both act as Mod alone; no chord toggles caps lock."
    exit 0
else
    echo "ERROR: copilot-mod setup incomplete (see messages above)."
    exit 1
fi
