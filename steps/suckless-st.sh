#!/bin/bash
# steps/suckless-st.sh — SUCKLESS ST (X11 terminal emulator)
# Builds and installs st from suckless.org with custom configs.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "SUCKLESS ST (terminal)"
echo "*****************************************************"

ok=true

# ── Build dependencies ──
echo "Installing build deps for st..."
install_pkg "libX11 libXft libXrender freetype fontconfig pkg-config"

if $ok; then
    mkdir -p /usr/local/src/suckless
    cd /usr/local/src/suckless

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
                echo "st installed successfully."
            fi
            cd ..
        fi
    fi
fi

# ── Install st wrapper ──
cp "$REPO_DIR/scripts/st-logged" /usr/local/bin/st-logged
chmod +x /usr/local/bin/st-logged
echo "  st-logged deployed to /usr/local/bin/st-logged"

if $ok; then
    echo "SUCCESS: Suckless st installed and configured."
    exit 0
else
    echo "ERROR: st setup encountered errors (st-logged script deployed anyway)."
    exit 1
fi
