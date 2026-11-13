#!/bin/bash
# steps/clipboard.sh - X11 CLIPBOARD (command line + sync between selections)
#
# st has NATIVE clipboard support (Ctrl+Shift+C copies the mouse selection into
# CLIPBOARD, Ctrl+Shift+V pastes CLIPBOARD) and needs no external tool. What was
# missing on this machine:
#
#   xclip      - command line access to the selections, so scripts and aliases
#                can copy/paste ("echo hi | clip", "clipout"). Also what many
#                other tools expect to exist.
#   autocutsel - keeps PRIMARY (mouse selection) and CLIPBOARD in sync and keeps
#                the last value after the owning application exits. Without it,
#                text selected in the terminal is only in PRIMARY (middle-click
#                paste), which is why "copy in terminal, paste in browser" felt
#                broken: Chrome's Ctrl+V reads CLIPBOARD, not PRIMARY.
#
# Deployed pieces:
#   /usr/local/bin/clipboard-ensure   started per X session by dwm-start
#   ~/.bashrc aliases clip / clipout / clipp (dotfiles/shell/bashrc)
#
# Idempotent: install_sbo skips installed packages; the helper is only rewritten
# when it changed.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "CLIPBOARD (xclip + autocutsel)"
echo "*****************************************************"

ok=true

# ── 1. Build/run deps (headers for the two small C programs) ──────────
echo "Ensuring X11 build libraries..."
install_pkg "libX11 libXmu libXaw libXt" || true
devel_ok=true
for hdr in /usr/include/X11/Xlib.h /usr/include/X11/Xmu/Xmu.h /usr/include/X11/Xaw/Simple.h; do
    [ -f "$hdr" ] || { echo "  WARNING: missing $hdr"; devel_ok=false; }
done

# ── 2. Install xclip + autocutsel via sbopkg (SBo 15.0) ───────────────
echo "Installing xclip and autocutsel..."
if ! install_sbo "xclip autocutsel"; then
    echo "ERROR: xclip/autocutsel install failed (see sbopkg log)"
    ok=false
fi

# ── 3. Per-session sync helper ───────────────────────────────────────
SRC="$REPO_DIR/scripts/clipboard-ensure"
DEST="/usr/local/bin/clipboard-ensure"
if [ ! -f "$SRC" ]; then
    echo "ERROR: $SRC missing"
    ok=false
else
    if [ -f "$DEST" ] && cmp -s "$SRC" "$DEST"; then
        echo "  $DEST already up to date"
    else
        install -Dm 755 "$SRC" "$DEST" && echo "  installed $DEST"
    fi
fi

# ── 4. Verify the binaries ───────────────────────────────────────────
if command -v xclip >/dev/null 2>&1; then
    echo "  xclip: $(command -v xclip)"
else
    echo "ERROR: xclip not on PATH"
    ok=false
fi
if command -v autocutsel >/dev/null 2>&1; then
    echo "  autocutsel: $(command -v autocutsel)"
else
    echo "ERROR: autocutsel not on PATH"
    ok=false
fi
$devel_ok || echo "  note: missing headers above are only needed to rebuild"

# ── 5. Headless end-to-end check (no touch to the live session) ───────
# Proves xclip can own and serve CLIPBOARD, and that autocutsel keeps the value
# after the writer's selection is replaced. Uses its own Xvfb display.
if $ok && command -v Xvfb >/dev/null 2>&1; then
    TEST_DISPLAY=":${CLIPBOARD_TEST_DISPLAY:-93}"
    # This Xvfb build defaults a 1280x1024 CRTC, so the screen must be at
    # least that large (800x600 aborts with "CRTC 0 size exceeds screen").
    Xvfb "$TEST_DISPLAY" -screen 0 1600x1200x24 -nolisten tcp >/dev/null 2>&1 &
    xvfb_pid=$!
    i=0
    while [ $i -lt 30 ] && ! DISPLAY="$TEST_DISPLAY" xdpyinfo >/dev/null 2>&1; do
        sleep 0.1; i=$((i+1))
    done
    if DISPLAY="$TEST_DISPLAY" xdpyinfo >/dev/null 2>&1; then
        export DISPLAY="$TEST_DISPLAY"
        # stderr silenced on writes: xclip forks to keep owning the selection,
        # and that child prints "X connection broken" when Xvfb goes away.
        printf 'clipboard self-test\n' | xclip -selection clipboard 2>/dev/null
        got=$(xclip -selection clipboard -o 2>/dev/null)
        if [ "$got" = "clipboard self-test" ]; then
            echo "  self-test: CLIPBOARD set/read OK ($TEST_DISPLAY)"
        else
            echo "ERROR: self-test could not read back CLIPBOARD (got '$got')"
            ok=false
        fi
        # autocutsel must mirror CLIPBOARD into PRIMARY. Start foreground
        # instances with explicit PIDs: never pkill by name here, that would
        # also kill the live session's sync.
        autocutsel -selection CLIPBOARD 2>/dev/null & ac1=$!
        autocutsel -selection PRIMARY 2>/dev/null & ac2=$!
        sleep 0.5
        printf 'sync-test\n' | xclip -selection clipboard 2>/dev/null
        # autocutsel reacts on its own poll tick (~1 s); wait up to 4 s instead
        # of assuming one fixed sleep is enough.
        gotp=""
        i=0
        while [ $i -lt 40 ]; do
            gotp=$(xclip -selection primary -o 2>/dev/null)
            [ "$gotp" = "sync-test" ] && break
            sleep 0.1
            i=$((i+1))
        done
        if [ "$gotp" = "sync-test" ]; then
            echo "  self-test: autocutsel CLIPBOARD -> PRIMARY sync OK"
        else
            echo "  WARNING: autocutsel sync not confirmed (PRIMARY='$gotp')"
        fi
        kill "$ac1" "$ac2" 2>/dev/null || true
        wait "$ac1" "$ac2" 2>/dev/null || true
    else
        echo "  WARNING: could not start Xvfb on $TEST_DISPLAY — skipping self-test"
    fi
    kill "$xvfb_pid" 2>/dev/null || true
    wait "$xvfb_pid" 2>/dev/null || true
    unset DISPLAY
fi

if $ok; then
    echo "SUCCESS: clipboard tools installed."
    echo "  terminal keys : Ctrl+Shift+C (copy mouse selection) / Ctrl+Shift+V (paste)"
    echo "  command line  : echo hi | clip   |   clipout"
    echo "  sync          : clipboard-ensure runs at every X start (dwm-start)"
    exit 0
fi
echo "ERROR: clipboard install incomplete (see messages above)."
exit 1
