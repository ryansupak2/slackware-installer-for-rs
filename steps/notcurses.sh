#!/bin/bash
# steps/notcurses.sh - NOTCURSES (modern TUI library, plus its demo program)
#
# Installs the notcurses shared library, headers, the notcurses-info tool and
# `notcurses-demo` — the visual test suite that is the natural way to check
# that a terminal emulator handles the capabilities notcurses exercises
# (truecolor, direct color, kitty graphics, braille, half blocks, ...):
#
#   kitty notcurses-demo -p
#
# It is a terminal-capability demo, not a desktop app: nothing here changes
# st, dwm or any default.
#
# Idempotent: install_pkg/install_sbo skip already-installed packages.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"
NOTCURSES_VERSION="3.0.17"   # SBo 15.0 pin (libraries/notcurses)

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "NOTCURSES (TUI library + notcurses-demo)"
echo "*****************************************************"

ok=true

# ── 1. Build/run dependencies ─────────────────────────────────────────
# cmake drives the build; ncursesw + libunistring are hard requirements;
# doctest is SBo's REQUIRES (the test harness); ffmpeg is optional
# (multimedia/visuals in the demo) and already installed on this machine.
echo "Installing notcurses dependencies..."
install_pkg "cmake ncurses libunistring libdeflate zlib" || ok=false
install_sbo "doctest" || ok=false

# ── 2. Build/install notcurses via sbopkg (SBo, pinned) ───────────────
# cmake + make print a lot; the ticker adds one progress line every 5 s
# without touching (or buffering) that output. Removing the marker file
# stops it, so nothing has to be signalled.
if $ok; then
    echo "Building notcurses $NOTCURSES_VERSION..."
    ticker_marker=$(mktemp /tmp/notcurses-build-ticker.XXXXXX)
    "$REPO_DIR/scripts/build-ticker.sh" "notcurses" /tmp/SBo "$ticker_marker" 5 &
    ticker_pid=$!
    install_sbo "notcurses" || ok=false
    rm -f "$ticker_marker"
    wait "$ticker_pid" 2>/dev/null || true
fi

# ── 3. Verify ─────────────────────────────────────────────────────────
if $ok; then
    if [ ! -x /usr/bin/notcurses-info ] || [ ! -x /usr/bin/notcurses-demo ]; then
        echo "ERROR: notcurses-info / notcurses-demo missing after the build."
        ok=false
    else
        # `notcurses-info -v` needs a TTY (get_tty_fd fails when stdout is a
        # pipe), so report the installed package version instead.
        nc_pkg=$(ls -d /var/log/packages/notcurses-[0-9]* 2>/dev/null | head -1)
        nc_ver=${nc_pkg##*/notcurses-}; nc_ver=${nc_ver%%-*}
        echo "  installed: notcurses ${nc_ver:-unknown}"
        echo "  demo:      /usr/bin/notcurses-demo"
    fi
fi

if $ok; then
    echo "  Try it in any terminal (st or kitty): notcurses-demo -p -d 1:file"
    echo "SUCCESS: notcurses + notcurses-demo installed."
    exit 0
else
    echo "ERROR: notcurses setup encountered errors."
    exit 1
fi
