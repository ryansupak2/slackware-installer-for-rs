#!/bin/bash
# steps/wayland-base.sh - WAYLAND BASE (wlroots + mesa + seatd + wayland from source)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "WAYLAND BASE"
echo "*****************************************************"

ok=true

# --- 1. Official packages (already installed with X series) ---
install_pkg "libinput libxkbcommon mesa" || true

# --- 2. SBo packages ---
install_sbo "wlroots bemenu seatd" || {
    echo "WARNING: some SBo packages had issues (non-fatal)."
}

# --- 3. meson (needed to build wayland from source) ---
echo "Installing meson via pip..."
if ! command -v meson >/dev/null 2>&1; then
    pip3 install meson 2>/dev/null || {
        echo "ERROR: pip3 install meson failed"
        ok=false
    }
fi

# --- 4. Build wayland from source (not in SBo 15.0) ---
if $ok && ! ldconfig -p 2>/dev/null | grep -q libwayland-server; then
    echo "Building wayland from source..."
    SRC=/usr/local/src/wayland
    mkdir -p "$SRC"
    cd "$SRC"
    rm -rf wayland
    if git clone --depth 1 https://gitlab.freedesktop.org/wayland/wayland 2>/dev/null; then
        cd wayland
        meson setup build --prefix=/usr >/dev/null 2>&1 || { echo "ERROR: wayland meson failed"; ok=false; }
        if $ok; then ninja -C build >/dev/null 2>&1 || { echo "ERROR: wayland build failed"; ok=false; }; fi
        if $ok; then ninja -C build install >/dev/null 2>&1 || { echo "ERROR: wayland install failed"; ok=false; }; fi
        $ok && { ldconfig 2>/dev/null || true; echo "  wayland: OK"; }
    else
        echo "ERROR: wayland clone failed"; ok=false
    fi
fi

# --- 5. Build wayland-protocols from source (not in SBo 15.0) ---
if $ok && [ ! -f /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml ]; then
    echo "Building wayland-protocols from source..."
    SRC=/usr/local/src/wayland
    mkdir -p "$SRC"
    cd "$SRC"
    rm -rf wayland-protocols
    if git clone --depth 1 https://gitlab.freedesktop.org/wayland/wayland-protocols 2>/dev/null; then
        cd wayland-protocols
        meson setup build --prefix=/usr >/dev/null 2>&1 || { echo "ERROR: wayland-protocols meson failed"; ok=false; }
        if $ok; then ninja -C build >/dev/null 2>&1 || { echo "ERROR: wayland-protocols build failed"; ok=false; }; fi
        if $ok; then ninja -C build install >/dev/null 2>&1 || { echo "ERROR: wayland-protocols install failed"; ok=false; }; fi
        $ok && echo "  wayland-protocols: OK"
    else
        echo "ERROR: wayland-protocols clone failed"; ok=false
    fi
fi

if $ok; then
    # udev — Slackware's rc.M already handles udev
    udevadm trigger --subsystem-match=input --action=change 2>/dev/null || true
    udevadm settle -t 3 2>/dev/null || true

    # Disable system seatd — dwl-start uses seatd-launch per-session
    killall seatd 2>/dev/null || true
    rm -f /run/seatd.sock 2>/dev/null || true

    # dbus for IPC (elogind not used on Slackware — ConsoleKit2 handles sessions)
    chmod +x /etc/rc.d/rc.messagebus 2>/dev/null || true
    /etc/rc.d/rc.messagebus start 2>/dev/null || true

    # Add root to input/video groups (needed for /dev/input/* access)
    for grp in input video audio; do
        groups root 2>/dev/null | grep -q "\b$grp\b" || usermod -aG "$grp" root 2>/dev/null || true
    done

    # Install boot-time seatd cleanup via rc.local
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
