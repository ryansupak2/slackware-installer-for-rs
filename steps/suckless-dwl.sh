#!/bin/bash
# steps/suckless-dwl.sh - SUCKLESS DWL (Wayland compositor, dwm port)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "SUCKLESS DWL"
echo "*****************************************************"

ok=true

echo "Installing build deps for dwl + somebar..."
# Official packages (D/X series — gcc/make come from D series)
install_pkg "libinput libxkbcommon pkg-config cairo pango"
# SBo build dependencies
install_sbo "scdoc samurai wtype"

# meson (needed for somebar build — not in SBo, use pip)
echo "Ensuring meson is available..."
if ! command -v meson >/dev/null 2>&1; then
    pip3 install meson 2>/dev/null || {
        echo "ERROR: pip3 install meson failed"
        ok=false
    }
fi

if $ok; then
    mkdir -p /usr/local/src/suckless
    cd /usr/local/src/suckless

    echo "Installing Suckless dwl..."
    rm -rf dwl
    if ! git clone --depth 1 https://codeberg.org/dwl/dwl; then
        echo "ERROR: failed to git clone dwl."
        ok=false
    else
        cd dwl
        cp -f "$REPO_DIR/dotfiles/suckless/dwl/config.h" config.h
        cp -f "$REPO_DIR/dotfiles/suckless/dwl/dwl.c.patched" dwl.c
        cp -f "$REPO_DIR/dotfiles/suckless/dwl/config.mk" config.mk
        if ! make clean install; then
            echo "ERROR: make clean install for dwl failed."
            ok=false
        fi
        cd ..
    fi
fi

if $ok; then
    echo "Installing somebar (dwl companion status bar)..."
    rm -rf somebar
    if ! git clone https://git.sr.ht/~raphi/somebar; then
        echo "ERROR: failed to git clone somebar."
        ok=false
    else
        cd somebar
        cp "$REPO_DIR/dotfiles/somebar/config.hpp" src/config.hpp
        cp "$REPO_DIR/dotfiles/somebar/common.hpp" src/common.hpp
        cp "$REPO_DIR/dotfiles/somebar/bar.cpp"    src/bar.cpp
        cp "$REPO_DIR/dotfiles/somebar/main.cpp"  src/main.cpp
        meson setup build && ninja -C build && ninja -C build install
        if [ $? -ne 0 ]; then
            echo "ERROR: build/install for somebar failed."
            ok=false
        fi
        cd ..
    fi
fi

if $ok; then
    echo "Installing dwl-start session launcher + status script..."
    cp "$REPO_DIR/scripts/dwl-start.sh" /usr/local/bin/dwl-start
    chmod +x /usr/local/bin/dwl-start
    cp "$REPO_DIR/scripts/dwl-status.sh" /usr/local/bin/dwl-status
    chmod +x /usr/local/bin/dwl-status
    echo "  dwl-start deployed to /usr/local/bin/dwl-start"
    echo "  dwl-status deployed to /usr/local/bin/dwl-status"
    echo "Installing shell shortcuts + neofetch launcher..."
    cp "$REPO_DIR/scripts/g" /usr/local/bin/g
    chmod +x /usr/local/bin/g
    cp "$REPO_DIR/scripts/gui" /usr/local/bin/gui
    chmod +x /usr/local/bin/gui
    cp "$REPO_DIR/scripts/neofetch-hold.sh" /usr/local/bin/neofetch-hold
    chmod +x /usr/local/bin/neofetch-hold

    echo "SUCCESS: Suckless dwl and somebar installed and configured."
    exit 0
else
    echo "ERROR: dwl setup encountered errors."
    exit 1
fi
