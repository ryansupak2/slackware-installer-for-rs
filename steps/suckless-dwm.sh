#!/bin/bash
# steps/suckless-dwm.sh - SUCKLESS DWM (X11 window manager)
# Builds and installs dwm + st from suckless.org with custom configs.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "SUCKLESS DWM"
echo "*****************************************************"

ok=true

echo "Installing build deps for dwm + st..."
# X11 development libraries + base X11 packages (Slackware X series)
install_pkg "libX11 libXft libXinerama libXext libXrender freetype fontconfig pkg-config"
# Ensure startx is available (xinit package)
if ! command -v startx >/dev/null 2>&1; then
    echo "WARNING: startx not found. Install the xinit package from Slackware X series."
fi

if $ok; then
    mkdir -p /usr/local/src/suckless
    cd /usr/local/src/suckless

    # ── dwm ──────────────────────────────────────────────────────
    if [ -x /usr/local/bin/dwm ] && \
       cmp -s "$REPO_DIR/dotfiles/suckless/dwm/config.h" /usr/local/src/suckless/dwm-stamp/config.h 2>/dev/null && \
       cmp -s "$REPO_DIR/dotfiles/suckless/dwm/dwm.c" /usr/local/src/suckless/dwm-stamp/dwm.c 2>/dev/null; then
        echo "dwm already installed — skipping"
    else
        echo "Installing Suckless dwm..."
        rm -rf dwm
        if ! git clone --depth 1 --branch 6.5 https://git.suckless.org/dwm; then
            echo "ERROR: failed to git clone dwm."
            ok=false
        else
            cd dwm
            # Copy our config.h and patched dwm.c (replaces vanilla dwm.c)
            cp -f "$REPO_DIR/dotfiles/suckless/dwm/config.h" config.h
            cp -f "$REPO_DIR/dotfiles/suckless/dwm/dwm.c" dwm.c
            cp -f "$REPO_DIR/dotfiles/suckless/dwm/config.mk" config.mk
            if ! make clean install; then
                echo "ERROR: make clean install for dwm failed."
                ok=false
            else
                # Stamp the dotfiles so we can detect changes on reinstall
                mkdir -p /usr/local/src/suckless/dwm-stamp
                cp -f "$REPO_DIR/dotfiles/suckless/dwm/config.h" /usr/local/src/suckless/dwm-stamp/config.h
                cp -f "$REPO_DIR/dotfiles/suckless/dwm/dwm.c" /usr/local/src/suckless/dwm-stamp/dwm.c
            fi
            cd ..
        fi
    fi
fi

if $ok; then
    # ── st (suckless terminal) ───────────────────────────────────
    if [ -x /usr/local/bin/st ] && \
       cmp -s "$REPO_DIR/dotfiles/suckless/st/config.h" /usr/local/src/suckless/st-stamp/config.h 2>/dev/null && \
       cmp -s "$REPO_DIR/dotfiles/suckless/st/st.c" /usr/local/src/suckless/st-stamp/st.c 2>/dev/null && \
       cmp -s "$REPO_DIR/dotfiles/suckless/st/st.h" /usr/local/src/suckless/st-stamp/st.h 2>/dev/null && \
       cmp -s "$REPO_DIR/dotfiles/suckless/st/x.c" /usr/local/src/suckless/st-stamp/x.c 2>/dev/null; then
        echo "st already installed — skipping"
    else
        echo "Installing Suckless st..."
        rm -rf st
        if ! git clone --depth 1 --branch 0.9.2 https://git.suckless.org/st; then
            echo "ERROR: failed to git clone st."
            ok=false
        else
            cd st
            cp -f "$REPO_DIR/dotfiles/suckless/st/config.h" config.h
            cp -f "$REPO_DIR/dotfiles/suckless/st/st.c" st.c
            cp -f "$REPO_DIR/dotfiles/suckless/st/st.h" st.h
            cp -f "$REPO_DIR/dotfiles/suckless/st/x.c" x.c
            if ! make clean install; then
                echo "ERROR: make clean install for st failed."
                ok=false
            else
                mkdir -p /usr/local/src/suckless/st-stamp
                cp -f "$REPO_DIR/dotfiles/suckless/st/config.h" /usr/local/src/suckless/st-stamp/config.h
                cp -f "$REPO_DIR/dotfiles/suckless/st/st.c" /usr/local/src/suckless/st-stamp/st.c
                cp -f "$REPO_DIR/dotfiles/suckless/st/st.h" /usr/local/src/suckless/st-stamp/st.h
                cp -f "$REPO_DIR/dotfiles/suckless/st/x.c" /usr/local/src/suckless/st-stamp/x.c
            fi
            cd ..
        fi
    fi
fi

if $ok; then
    # ── xlock (X11 screen locker) ────────────────────────────────
    # xlockmore is the standard X11 locker with PAM support.
    # Install from Slackware packages if not already present.
    if [ -x /usr/bin/xlock ] || [ -x /usr/local/bin/xlock ]; then
        echo "xlock already installed — skipping"
    else
        echo "Installing xlockmore (X11 screen locker)..."
        install_pkg "xlockmore" 2>/dev/null || {
            # If not in Slackware, try SBo
            install_sbo "xlockmore" 2>/dev/null || {
                echo "WARNING: xlockmore not available — screen locking in X11 will fall back to physlock"
            }
        }
    fi
fi

# ── Always deploy: session launcher + status scripts (independent of build) ──
echo "Installing dwm-start session launcher + status script..."
cp "$REPO_DIR/scripts/dwm-start.sh" /usr/local/bin/dwm-start
chmod +x /usr/local/bin/dwm-start
cp "$REPO_DIR/scripts/dwm-status.sh" /usr/local/bin/dwm-status
chmod +x /usr/local/bin/dwm-status
cp "$REPO_DIR/scripts/toggle-bar.sh" /usr/local/bin/toggle-bar.sh
chmod +x /usr/local/bin/toggle-bar.sh
cp "$REPO_DIR/scripts/toggle-hide-mode.sh" /usr/local/bin/toggle-hide-mode.sh
chmod +x /usr/local/bin/toggle-hide-mode.sh
cp "$REPO_DIR/scripts/temp-msg.sh" /usr/local/bin/temp-msg.sh
chmod +x /usr/local/bin/temp-msg.sh
cp "$REPO_DIR/scripts/broadcast.sh" /usr/local/bin/broadcast
chmod +x /usr/local/bin/broadcast

echo "  dwm-start deployed to /usr/local/bin/dwm-start"
echo "  dwm-status deployed to /usr/local/bin/dwm-status"
echo "  toggle-bar deployed to /usr/local/bin/toggle-bar.sh"
echo "  toggle-hide-mode deployed to /usr/local/bin/toggle-hide-mode.sh"
echo "  temp-msg deployed to /usr/local/bin/temp-msg.sh"

echo "Installing shell shortcuts..."
cp "$REPO_DIR/scripts/x" /usr/local/bin/x
chmod +x /usr/local/bin/x
echo "  x deployed to /usr/local/bin/x"

if $ok; then
    echo "SUCCESS: Suckless dwm + st installed and configured."
    exit 0
else
    echo "ERROR: dwm setup encountered errors (scripts deployed anyway)."
    exit 1
fi
