#!/bin/bash
# steps/vnc.sh - VNC SCREEN SHARING (x11vnc)
#
# Installs x11vnc (X11 VNC server) from SBo with password auth.
# Deploys the vnc manager script to /usr/local/bin/vnc.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "VNC SCREEN SHARING (x11vnc)"
echo "*****************************************************"

ok=true

echo "Installing x11vnc from SBo..."
if command -v x11vnc >/dev/null 2>&1; then
    echo "  x11vnc already installed — skipping"
else
    install_sbo "x11vnc" || { echo "ERROR: x11vnc SBo build failed"; ok=false; }
fi

if $ok; then
    echo "Configuring x11vnc authentication..."
    PASSWD_DIR="/usr/local/etc/x11vnc"
    mkdir -p "$PASSWD_DIR"

    if [ ! -f "$PASSWD_DIR/passwd" ]; then
        echo "  Creating x11vnc password file..."
        VNC_PASS=$(head -c 10 /dev/urandom | base64 | tr -d '+/=' | head -c 10)
        x11vnc -storepasswd "$VNC_PASS" "$PASSWD_DIR/passwd" 2>/dev/null
        chmod 600 "$PASSWD_DIR/passwd"
        echo "  VNC password: ${VNC_PASS}"
        echo "  (Run 'vnc start' from within your X11/dwm session, then connect with this password)"
    else
        echo "  x11vnc password file already exists — skipping."
    fi
fi

if $ok; then
    echo "Installing screen sharing manager script..."
    if ! cp "$REPO_DIR/scripts/vnc.sh" /usr/local/bin/vnc || ! chmod +x /usr/local/bin/vnc; then
        echo "ERROR: failed to install vnc script."
        ok=false
    fi
fi

if $ok; then
    echo "SUCCESS: VNC screen sharing installed and configured."
    exit 0
else
    echo "ERROR: VNC setup encountered errors."
    exit 1
fi
