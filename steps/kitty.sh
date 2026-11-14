#!/bin/bash
# steps/kitty.sh - KITTY (GPU terminal emulator) as an EXTRA terminal
#
# st REMAINS THE DEFAULT TERMINAL on this machine. This step does not touch
# dwm's termcmd (dotfiles/suckless/dwm/config.h), does not alias `st`, and
# does not change ~/.bashrc. It only adds a second, GPU-rendered terminal that
# you start by name:
#
#   kitty
#
# Works for root and every human user with no per-user dotfiles:
#   /usr/bin/kitty                 world-executable (SBo build, pinned below)
#   /etc/xdg/kitty/kitty.conf      system-wide defaults, merged by kitty
#                                  before any user config (kitty/cli.py:
#                                  SYSTEM_CONF), so ~/.config/kitty/kitty.conf
#                                  still overrides it
#   /usr/share/terminfo/x/xterm-kitty   installed by the kitty package
#
# Idempotent: an installed kitty of the pinned version is not rebuilt; the
# config is only rewritten when its content changed.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"
KITTY_VERSION="0.38.1"   # SBo 15.0 pin (slackbuilds.org/slackbuilds/15.0/system/kitty)

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "KITTY (GPU terminal emulator, extra — st stays default)"
echo "*****************************************************"

ok=true
have_version=""
if [ -x /usr/bin/kitty ]; then
    have_version=$(/usr/bin/kitty --version 2>/dev/null | awk 'NR==1{print $2}')
fi

# ── 1. Build + run dependencies ───────────────────────────────────────
# library deps come from kitty's setup.py checks:
#   harfbuzz, libpng, lcms2, fontconfig, libxxhash (pkg-config libxxhash),
#   openssl (libcrypto), mesa/libglvnd (pkg-config gl), zlib, python3, gcc
# simde is only a header include (<simde/x86/avx2.h> in simd-string-impl.h)
# and ships no .pc file, hence the SBo package.
# google-go-lang builds the `kitten` binary (setup.py: build_static_kittens
# needs go >= 1.23; the source tarball vendors its Go modules, so the build
# does not need the network).
# ttf-nerd-fonts-symbols is a BUILD dependency, not a nicety: setup.py's
# add_builtin_fonts() runs `fc-match -f '%{file}\n%{postscriptname}'
# term:postscriptname=SymbolsNFM` and aborts with "The font 'Symbols NERD
# Font Mono' was not found on your system" if fontconfig cannot resolve it
# (measured: the first build died exactly there).
# NOT installed on purpose:
#   librsync — SBo lists it, but kitty 0.38.1 has no librsync reference
#              anywhere in its source tree (`kitten diff` has its own
#              algorithm), so it would be dead weight.
if [ "$have_version" = "$KITTY_VERSION" ]; then
    echo "kitty $KITTY_VERSION already installed — skipping build"
else
    echo "Installing kitty build dependencies..."
    install_pkg "python3 pkg-config gcc gcc-g++ zlib harfbuzz libpng lcms2 fontconfig freetype openssl-solibs mesa libglvnd xxHash google-go-lang" || ok=false

    if $ok; then
        echo "Installing kitty build deps from SBo (simde headers, Nerd Font symbols)..."
        install_sbo "simde ttf-nerd-fonts-symbols" || ok=false
    fi

    # ── 2. Build/install kitty via sbopkg (SBo, pinned) ───────────────
    # The build prints ~300 gcc lines and takes several minutes. kitty's
    # own output is left untouched (nothing is piped or filtered); the
    # ticker just adds one progress line every 5 s: elapsed time, object
    # count and how many compilers are running, so "is it working?" never
    # needs a scrollback. Stop it by removing the marker file.
    if $ok; then
        echo "Building kitty $KITTY_VERSION (C + Python + one Go binary; several minutes)..."
        echo "  full build log: /var/log/sbopkg/sbopkg-build-log"
        ticker_marker=$(mktemp /tmp/kitty-build-ticker.XXXXXX)
        "$REPO_DIR/scripts/build-ticker.sh" "kitty" /tmp/SBo "$ticker_marker" 5 &
        ticker_pid=$!
        install_sbo "kitty" || ok=false
        rm -f "$ticker_marker"
        wait "$ticker_pid" 2>/dev/null || true
    fi
fi

# ── 3. Verify the binary ──────────────────────────────────────────────
if $ok; then
    if [ ! -x /usr/bin/kitty ]; then
        echo "ERROR: /usr/bin/kitty is missing after the build."
        ok=false
    else
        echo "  binary: $(/usr/bin/kitty --version 2>/dev/null | head -1)"
        if ! infocmp xterm-kitty >/dev/null 2>&1; then
            echo "ERROR: terminfo entry xterm-kitty is missing (kitty packages install it)."
            ok=false
        else
            echo "  terminfo: xterm-kitty present"
        fi
    fi
fi

# ── 4. System-wide config (one file for root + every user) ────────────
# /etc/xdg/kitty/kitty.conf is merged *before* user configs, so it is the
# system default and a user's own kitty.conf still wins.
if [ -f "$REPO_DIR/dotfiles/kitty/kitty.conf" ]; then
    mkdir -p /etc/xdg/kitty
    if [ -f /etc/xdg/kitty/kitty.conf ] && \
       cmp -s "$REPO_DIR/dotfiles/kitty/kitty.conf" /etc/xdg/kitty/kitty.conf; then
        echo "  /etc/xdg/kitty/kitty.conf already up to date"
    else
        install -m 644 "$REPO_DIR/dotfiles/kitty/kitty.conf" /etc/xdg/kitty/kitty.conf
        echo "  /etc/xdg/kitty/kitty.conf installed (system-wide defaults)"
    fi
else
    echo "ERROR: $REPO_DIR/dotfiles/kitty/kitty.conf missing."
    ok=false
fi

# ── 5. Report ─────────────────────────────────────────────────────────
if $ok; then
    echo "  st is untouched and still the default terminal (dwm Mod+Enter)."
    echo "  Start kitty by name; system-wide settings: /etc/xdg/kitty/kitty.conf"
    echo "SUCCESS: kitty installed and configured."
    exit 0
else
    echo "ERROR: kitty setup encountered errors."
    exit 1
fi
