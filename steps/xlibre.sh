#!/bin/bash
# steps/xlibre.sh — XLIBRE X SERVER (modern X11)
# Builds and installs XLibre (community fork of X.Org Server) + ABI-matched
# libinput driver from source. Installs to /usr/local.
# Original Xorg is preserved at /usr/libexec/Xorg.orig.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "XLIBRE X SERVER"
echo "*****************************************************"

PREFIX="/usr/local"
PKG_CONFIG_PATH="${PREFIX}/lib64/pkgconfig:${PREFIX}/share/pkgconfig:${PKG_CONFIG_PATH}"
export PKG_CONFIG_PATH

# ── Ensure meson ≥ 0.61.0 (XLibre requirement) ────────────────
MESON_MIN="0.61.0"
MESON_CUR=$(meson --version 2>/dev/null || echo "0")
if ! python3 -c "from packaging.version import Version; exit(0 if Version('$MESON_CUR') >= Version('$MESON_MIN') else 1)" 2>/dev/null; then
    echo "Upgrading meson ($MESON_CUR → ≥ $MESON_MIN) for XLibre..."
    pip3 install "meson>=${MESON_MIN}" || { echo "ERROR: meson upgrade failed"; exit 1; }
    echo "  meson $(meson --version) installed"
else
    echo "meson $MESON_CUR (≥ $MESON_MIN) — OK"
fi
# ── System build dependencies ───────────────────────────────
echo "Checking system build dependencies..."
install_pkg "libX11 libXext libXfont2 libXau libXdmcp libxcb xcb-proto xtrans"
install_pkg "libXrandr libXrender libXi libXtst libXScrnSaver libXpm libXaw"
install_pkg "libXcomposite libXcursor libXdamage libXfixes libXft libXinerama"
install_pkg "libXmu libXpresent libXres libXt libXv libXvMC libXxf86vm"
install_pkg "libdmx libfontenc libpciaccess"
install_pkg "pixman libdrm mesa libepoxy libtirpc nettle libunwind libinput"
install_pkg "xkbcomp font-util"

# ── helpers ─────────────────────────────────────────────────
clone_if_missing() {
    local url="$1" dir="$2"
    if [ ! -d "$dir/.git" ]; then
        echo "  Cloning $url..."
        git clone --depth 1 "$url" "$dir" || { echo "ERROR: clone failed: $url"; exit 1; }
    fi
}

meson_build_install() {
    local dir="$1" prefix="$2" msg="$3"
    shift 3
    echo "  Building $msg..."
    cd "$dir" || { echo "ERROR: cd $dir failed"; exit 1; }
    rm -rf build
    meson setup build --prefix="$prefix" --buildtype=release "$@" || {
        echo "ERROR: meson setup failed for $msg"
        exit 1
    }
    ninja -C build -j"$(nproc)" || { echo "ERROR: ninja failed for $msg"; exit 1; }
    ninja -C build install || { echo "ERROR: install failed for $msg"; exit 1; }
}

# ── libxcvt ─────────────────────────────────────────────────
LIBCVT_SRC="$REPO_DIR/sources/libxcvt"

if pkg-config --exists libxcvt 2>/dev/null; then
    echo "libxcvt $(pkg-config --modversion libxcvt) already installed — skipping"
else
    echo "Building libxcvt (XLibre dependency)..."
    clone_if_missing "https://gitlab.freedesktop.org/xorg/lib/libxcvt.git" "$LIBCVT_SRC"
    meson_build_install "$LIBCVT_SRC" "$PREFIX" "libxcvt"
    ldconfig
fi

# ── xorgproto (newer than Slackware 15.0's 2021.5) ──────────
XORGPROTO_SRC="$REPO_DIR/sources/xorgproto"

if pkg-config --exists presentproto && [ "$(pkg-config --modversion presentproto)" != "1.2" ] 2>/dev/null; then
    echo "presentproto $(pkg-config --modversion presentproto) (>= 1.4) already installed — skipping"
else
    echo "Building xorgproto (system presentproto 1.2 is too old)..."
    clone_if_missing "https://github.com/X11Libre/mirror.fdo.xorgproto.git" "$XORGPROTO_SRC"
    meson_build_install "$XORGPROTO_SRC" "$PREFIX" "xorgproto"
fi

# ── XLibre Xserver ──────────────────────────────────────────
XLIBRE_SRC="$REPO_DIR/sources/xserver"
XLIBRE_STAMP="$XLIBRE_SRC/.xlibre-built"
XLIBRE_GIT_URL="https://github.com/X11Libre/xserver.git"

clone_if_missing "$XLIBRE_GIT_URL" "$XLIBRE_SRC"

# Idempotency: check if current git HEAD matches stamp
CURRENT_HASH=$(cd "$XLIBRE_SRC" && git log -1 --format='%H')
STAMPED_HASH=$(cat "$XLIBRE_STAMP" 2>/dev/null || echo "")

if [ "$CURRENT_HASH" = "$STAMPED_HASH" ] && [ -x "$PREFIX/bin/Xorg" ]; then
    echo "XLibre server already built (hash: ${CURRENT_HASH:0:12}) — skipping"
else
    echo "Building XLibre server..."

    # Apply glibc 2.33 compatibility fix: replace osdep.h with patched version
    cp "$REPO_DIR/sources/xlibre/osdep.h" "$XLIBRE_SRC/os/osdep.h"

    cd "$XLIBRE_SRC"
    rm -rf build
    meson setup build \
        --prefix="$PREFIX" \
        --libdir=lib64 \
        --buildtype=release \
        -Dxephyr=false \
        -Dxnest=false \
        -Dxfbdev=false \
        -Dxquartz=false \
        -Dxwin=false \
        -Dxvfb=true \
        -Dxorg=true \
        -Dglamor=true \
        -Dglx=true \
        -Dglx_dri=true \
        -Ddri1=auto \
        -Ddri2=true \
        -Ddri3=true \
        -Ddrm=true \
        -Dgbm=true \
        -Dpciaccess=true \
        -Dudev=true \
        -Dudev_kms=true \
        -Dsystemd_logind=true \
        -Dsystemd_notify=false \
        -Dseatd_libseat=false \
        -Dipv6=true \
        -Dxdmcp=true \
        -Dxcsecurity=false \
        -Dxselinux=auto \
        -Dnamespace=true \
        -Dxinerama=true \
        -Dxv=true \
        -Dxvmc=true \
        -Dscreensaver=true \
        -Dxres=true \
        -Ddpms=true \
        -Ddga=auto \
        -Dxf86bigfont=false \
        -Dint10=auto \
        -Dsuid_wrapper=false \
        -Ddocs=false \
        -Ddevel-docs=false \
        -Dtests=false \
        -Dmodule_dir=/usr/lib64/xorg/modules \
        -Dlog_dir=/var/log \
        -Ddefault_font_path=/usr/share/fonts \
        -Dfontrootdir=/usr/share/fonts \
        -Dxkb_dir=/usr/share/X11/xkb \
        -Dxkb_output_dir=/var/lib/xkb \
        -Dxkb_bin_dir=/usr/bin \
        -Dlisten_tcp=false \
        -Dlisten_unix=true \
        -Dlisten_local=true \
        -Dsha1=auto \
        -Dinput_thread=auto \
        || { echo "ERROR: meson setup failed"; exit 1; }

    ninja -C build -j"$(nproc)" || { echo "ERROR: build failed"; exit 1; }
    ninja -C build install || { echo "ERROR: install failed"; exit 1; }

    # Set suid bit for /dev/dri and input device access
    chmod u+s "$PREFIX/bin/Xorg"

    echo "$CURRENT_HASH" > "$XLIBRE_STAMP"
    echo "  XLibre server installed to $PREFIX/bin/Xorg"
fi

# ── xf86-input-libinput (ABI-matched, built against XLibre) ─
LIINPUT_SRC="$REPO_DIR/sources/xf86-input-libinput"
LIINPUT_STAMP="$LIINPUT_SRC/.built-stamp"
LIINPUT_GIT_URL="https://github.com/X11Libre/xf86-input-libinput.git"

clone_if_missing "$LIINPUT_GIT_URL" "$LIINPUT_SRC"

LIINPUT_HASH=$(cd "$LIINPUT_SRC" && git log -1 --format='%H')
LIINPUT_STAMPED=$(cat "$LIINPUT_STAMP" 2>/dev/null || echo "")

if [ "$LIINPUT_HASH" = "$LIINPUT_STAMPED" ] && [ -f /usr/lib64/xorg/modules/input/libinput_drv.so ]; then
    echo "xf86-input-libinput already built (hash: ${LIINPUT_HASH:0:12}) — skipping"
else
    meson_build_install "$LIINPUT_SRC" "$PREFIX" "xf86-input-libinput"
    echo "$LIINPUT_HASH" > "$LIINPUT_STAMP"

    # The driver installs to xlibre-25/input/; copy to the standard input path
    # so XLibre finds it (XLibre loads from modules/input/, not the versioned subdir).
    mkdir -p /usr/lib64/xorg/modules/input
    cp /usr/lib64/xorg/modules/xlibre-25/input/libinput_drv.so /usr/lib64/xorg/modules/input/libinput_drv.so
fi

# ── Wrapper script ──────────────────────────────────────────
WRAPPER="/usr/bin/Xorg"
WRAPPER_SRC="$REPO_DIR/dotfiles/xlibre/Xorg.wrapper"
WRAPPER_BACKUP="/usr/bin/Xorg.stock-xorg-backup"

if [ ! -f "$WRAPPER_BACKUP" ]; then
    echo "Backing up original Xorg wrapper..."
    cp "$WRAPPER" "$WRAPPER_BACKUP"
fi

echo "Installing XLibre wrapper..."
cp "$WRAPPER_SRC" "$WRAPPER"
chmod 755 "$WRAPPER"

# ── Preserve original Xorg binary ──────────────────────────
if [ -x /usr/libexec/Xorg ] && [ ! -f /usr/libexec/Xorg.orig ]; then
    echo "Preserving original Xorg binary..."
    cp /usr/libexec/Xorg /usr/libexec/Xorg.orig
fi

# ── ldconfig ────────────────────────────────────────────────
ldconfig

# ── Fix nvidia config (remove invalid Module directives from OutputClass) ──
for nv_conf in \
    "$PREFIX/share/X11/xorg.conf.d/10-nvidia-modules.conf" \
    /usr/share/X11/xorg.conf.d/10-nvidia-modules.conf \
    "$XLIBRE_SRC/build/hw/xfree86/compat/10-nvidia-modules.conf"; do
    if [ -f "$nv_conf" ] && grep -q '^[[:space:]]*Module[[:space:]]' "$nv_conf" 2>/dev/null; then
        echo "Fixing nvidia config: $nv_conf"
        sed -i '/^[[:space:]]*Module[[:space:]]"glx/d' "$nv_conf"
        sed -i '/^[[:space:]]*Module[[:space:]]"glxserver_nvidia/d' "$nv_conf"
    fi
done

echo ""
echo "SUCCESS: XLibre installed."
echo "  X server:      $PREFIX/bin/Xorg"
echo "  Wrapper:       $WRAPPER"
echo "  libinput:      /usr/lib64/xorg/modules/input/libinput_drv.so"
echo "  Fallback:      /usr/libexec/Xorg.orig (stock Slackware Xorg)"
echo ""
echo "Restart X to use XLibre (Ctrl+Alt+Backspace, then startx)."
exit 0
