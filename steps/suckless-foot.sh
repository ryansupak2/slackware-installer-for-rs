#!/bin/bash
# steps/suckless-foot.sh — FOOT TERMINAL (Wayland-native terminal emulator)
#
# Built from source instead of SBo because the SlackBuild uses -Werror
# and the vendored fcft triggers a deprecation warning that breaks the build.
# We use the same version SBo ships (1.14.0) which works with Slackware 15.0's
# xkbcommon 1.3.1, just with -Dwerror=false.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "FOOT TERMINAL (Wayland-native terminal emulator)"
echo "*****************************************************"

ok=true

if [ -x /usr/bin/foot ]; then
    echo "foot already installed: $(which foot)"
else
    echo "Installing foot build dependencies..."
    install_pkg "meson ninja scdoc" || ok=false

    if $ok; then
        SRC=/usr/local/src/foot
        mkdir -p "$SRC"
        cd "$SRC"
        rm -rf foot

        echo "Cloning foot 1.14.0..."
        if git clone --depth 1 --branch 1.14.0 https://codeberg.org/dnkl/foot; then
            cd foot
            # -Dwerror=false avoids the fcft deprecation warning killing the build
            # -Dbuildtype=release matches what the SBo SlackBuild does
            meson setup build --prefix=/usr -Dwerror=false -Dbuildtype=release || { echo "ERROR: foot meson failed"; ok=false; }
            if $ok; then ninja -C build || { echo "ERROR: foot build failed"; ok=false; }; fi
            if $ok; then ninja -C build install || { echo "ERROR: foot install failed"; ok=false; }; fi
            $ok && echo "  foot: OK"
        else
            echo "ERROR: foot clone failed"; ok=false
        fi
    fi
fi

if $ok; then
    echo "Deploying foot configuration..."
    mkdir -p /etc/xdg/foot
    cp "$REPO_DIR/dotfiles/foot/foot.ini" /etc/xdg/foot/foot.ini
    echo "  foot.ini deployed to /etc/xdg/foot/foot.ini"
    echo "SUCCESS: foot installed and configured."
    exit 0
else
    echo "ERROR: foot setup encountered errors."
    exit 1
fi
