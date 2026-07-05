#!/bin/bash
# steps/wayland-base.sh - WAYLAND BASE (all built from source for compatibility)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "WAYLAND BASE"
echo "*****************************************************"

ok=true

# --- 1. Official packages ---
install_pkg "libinput libxkbcommon mesa"

# --- 2. SBo packages ---
install_sbo "bemenu seatd" || { echo "ERROR: SBo packages failed"; ok=false; }

# --- 3. meson ---
echo "Installing latest meson via pip..."
pip3 install --upgrade meson 2>/dev/null || {
    echo "ERROR: pip3 install meson failed"
    ok=false
}

SRC=/usr/local/src/wayland

# --- 4. Build wayland from source ---
if $ok; then
    echo "Building wayland from source..."
    mkdir -p "$SRC"
    cd "$SRC"
    rm -rf wayland
    if git clone --depth 1 https://gitlab.freedesktop.org/wayland/wayland; then
        cd wayland
        meson setup build --prefix=/usr -Ddocumentation=false || { echo "ERROR: wayland meson failed"; ok=false; }
        if $ok; then ninja -C build || { echo "ERROR: wayland build failed"; ok=false; }; fi
        if $ok; then ninja -C build install || { echo "ERROR: wayland install failed"; ok=false; }; fi
        $ok && { ldconfig 2>/dev/null || true; echo "  wayland: OK"; }
    else
        echo "ERROR: wayland clone failed"; ok=false
    fi
fi

# --- 5. Build wayland-protocols from source ---
if $ok; then
    echo "Building wayland-protocols from source..."
    mkdir -p "$SRC"
    cd "$SRC"
    rm -rf wayland-protocols
    if git clone --depth 1 https://gitlab.freedesktop.org/wayland/wayland-protocols; then
        cd wayland-protocols
        meson setup build --prefix=/usr || { echo "ERROR: wayland-protocols meson failed"; ok=false; }
        if $ok; then ninja -C build || { echo "ERROR: wayland-protocols build failed"; ok=false; }; fi
        if $ok; then ninja -C build install || { echo "ERROR: wayland-protocols install failed"; ok=false; }; fi
        $ok && echo "  wayland-protocols: OK"
    else
        echo "ERROR: wayland-protocols clone failed"; ok=false
    fi
fi

# --- 6. Build libdrm from git HEAD (wlroots needs >= 2.4.129) ---
if $ok; then
    echo "Building libdrm from source..."
    cd /usr/local/src
    rm -rf libdrm
    if git clone --depth 1 https://gitlab.freedesktop.org/mesa/drm libdrm; then
        cd libdrm
        meson setup build --prefix=/usr -Dudev=true || { echo "ERROR: libdrm meson failed"; ok=false; }
        if $ok; then ninja -C build || { echo "ERROR: libdrm build failed"; ok=false; }; fi
        if $ok; then ninja -C build install || { echo "ERROR: libdrm install failed"; ok=false; }; fi
        $ok && { ldconfig 2>/dev/null || true; echo "  libdrm: OK"; }
    else
        echo "ERROR: libdrm clone failed"; ok=false
    fi
fi

# --- 7. Build pixman from git HEAD (wlroots needs >= 0.46.0) ---
if $ok; then
    echo "Building pixman from source..."
    cd /usr/local/src
    rm -rf pixman
    if git clone --depth 1 https://gitlab.freedesktop.org/pixman/pixman; then
        cd pixman
        meson setup build --prefix=/usr || { echo "ERROR: pixman meson failed"; ok=false; }
        if $ok; then ninja -C build || { echo "ERROR: pixman build failed"; ok=false; }; fi
        if $ok; then ninja -C build install || { echo "ERROR: pixman install failed"; ok=false; }; fi
        $ok && { ldconfig 2>/dev/null || true; echo "  pixman: OK"; }
    else
        echo "ERROR: pixman clone failed"; ok=false
    fi
fi

# --- 8. Build xkbcommon from git HEAD (wlroots needs >= 1.8.0) ---
if $ok; then
    echo "Building xkbcommon from source..."
    cd /usr/local/src
    rm -rf libxkbcommon
    if git clone --depth 1 https://github.com/xkbcommon/libxkbcommon; then
        cd libxkbcommon
        meson setup build --prefix=/usr -Denable-docs=false || { echo "ERROR: xkbcommon meson failed"; ok=false; }
        if $ok; then ninja -C build || { echo "ERROR: xkbcommon build failed"; ok=false; }; fi
        if $ok; then ninja -C build install || { echo "ERROR: xkbcommon install failed"; ok=false; }; fi
        $ok && { ldconfig 2>/dev/null || true; echo "  xkbcommon: OK"; }
    else
        echo "ERROR: xkbcommon clone failed"; ok=false
    fi
fi

# --- 9. Build libdisplay-info from source (wlroots DRM backend needs it) ---
if $ok; then
    echo "Building libdisplay-info from source..."
    cd /usr/local/src
    rm -rf libdisplay-info
    if git clone --depth 1 https://gitlab.freedesktop.org/emersion/libdisplay-info; then
        cd libdisplay-info
        meson setup build --prefix=/usr || { echo "ERROR: libdisplay-info meson failed"; ok=false; }
        if $ok; then ninja -C build || { echo "ERROR: libdisplay-info build failed"; ok=false; }; fi
        if $ok; then ninja -C build install || { echo "ERROR: libdisplay-info install failed"; ok=false; }; fi
        $ok && { ldconfig 2>/dev/null || true; echo "  libdisplay-info: OK"; }
    else
        echo "ERROR: libdisplay-info clone failed"; ok=false
    fi
fi

# --- 10. Build wlroots 0.19.0 from source ---
if $ok; then
    echo "Building wlroots 0.19.0 from source..."
    install_pkg "hwdata" || ok=false
    if $ok; then
        mkdir -p "$SRC"
        cd "$SRC"
        rm -rf wlroots
        if git clone --depth 1 --branch 0.19.0 https://gitlab.freedesktop.org/wlroots/wlroots; then
            cd wlroots
            # Relax EGL version check for Slackware 15.0's mesa 21.3.5
            sed -i "s/if eglext_version < 20210604/if eglext_version < 20200220/" render/meson.build
            # Relax version checks for system libraries
            sed -i "s/version: '>=2.4.129'/version: '>=2.4.109'/" meson.build
            sed -i "s/version: '>=1.8.0'/version: '>=1.3.1'/"   meson.build
            sed -i "s/version: '>=0.46.0'/version: '>=0.40.0'/" meson.build
            meson setup build --prefix=/usr -Dexamples=false -Dbackends=drm,libinput,x11 -Dsession=enabled -Drenderers=gles2 || { echo "ERROR: wlroots meson failed"; ok=false; }
            if $ok; then ninja -C build || { echo "ERROR: wlroots build failed"; ok=false; }; fi
            if $ok; then ninja -C build install || { echo "ERROR: wlroots install failed"; ok=false; }; fi
            $ok && { ldconfig 2>/dev/null || true; echo "  wlroots: OK"; }
        else
            echo "ERROR: wlroots clone failed"; ok=false
        fi
    fi
fi
if $ok; then
    udevadm trigger --subsystem-match=input --action=change 2>/dev/null || true
    udevadm settle -t 3 2>/dev/null || true
    killall seatd 2>/dev/null || true
    rm -f /run/seatd.sock 2>/dev/null || true
    chmod +x /etc/rc.d/rc.messagebus 2>/dev/null || true
    /etc/rc.d/rc.messagebus start 2>/dev/null || true
    for grp in input video audio; do
        groups root 2>/dev/null | grep -q "\b$grp\b" || usermod -aG "$grp" root 2>/dev/null || true
    done
    if [ -f /etc/rc.d/rc.local ]; then
        if ! grep -q "seatd" /etc/rc.d/rc.local 2>/dev/null; then
            cat >> /etc/rc.d/rc.local << 'EOF'

# Wayland seatd cleanup (added by post-install-global.sh)
killall seatd 2>/dev/null || true
rm -f /run/seatd.sock 2>/dev/null || true
udevadm trigger --subsystem-match=input --action=change 2>/dev/null || true
EOF
        fi
    fi
    echo "SUCCESS: Wayland base installed."
    exit 0
else
    echo "ERROR: Wayland base setup encountered errors."
    exit 1
fi
