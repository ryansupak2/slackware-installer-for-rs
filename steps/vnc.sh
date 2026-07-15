#!/bin/bash
# steps/vnc.sh - VNC SCREEN SHARING (TigerVNC + wayvnc)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "VNC SCREEN SHARING (wayvnc)"
echo "*****************************************************"

ok=true

echo "Installing VNC packages..."
# fltk is SBo; tigervnc is in Slackware /extra
install_sbo "fltk" || { echo "ERROR: fltk not available"; ok=false; }
# Download tigervnc from /extra
if $ok && ! command -v vncviewer >/dev/null 2>&1; then
    echo "  Downloading tigervnc from Slackware /extra..."
    TIGER_MIRROR="https://mirrors.slackware.com/slackware/slackware64-15.0/extra/tigervnc"
    TIGER_PKG=$(curl -s "$TIGER_MIRROR/" 2>/dev/null | grep -o 'tigervnc-[0-9._-]*x86_64[^"]*\.txz' | head -1)
    if [ -n "$TIGER_PKG" ]; then
        wget -q "$TIGER_MIRROR/$TIGER_PKG" -O /tmp/tigervnc.txz && installpkg /tmp/tigervnc.txz && rm -f /tmp/tigervnc.txz || { echo "ERROR: tigervnc install failed"; ok=false; }
    else
        echo "ERROR: could not find tigervnc in /extra"; ok=false
    fi
fi
# gnutls is in official N series
if ! install_pkg "gnutls"; then
    echo "WARNING: gnutls not installed (needed for TLS certs)"
fi

if $ok; then
    echo "Configuring wayvnc authentication..."
    mkdir -p /etc/wayvnc /usr/local/etc/wayvnc

    # Generate self-signed TLS cert if not already present
    if [ ! -f /etc/wayvnc/cert.pem ] || [ ! -f /etc/wayvnc/key.pem ]; then
        echo "  Generating self-signed TLS certificate for VNC auth..."
        if command -v openssl >/dev/null 2>&1; then
            openssl req -x509 -newkey rsa:2048 \
                -keyout /etc/wayvnc/key.pem \
                -out /etc/wayvnc/cert.pem \
                -days 3650 -nodes \
                -subj "/CN=screen-share" 2>/dev/null
            chmod 644 /etc/wayvnc/key.pem
            chmod 644 /etc/wayvnc/cert.pem
        else
            echo "  WARNING: openssl not found; TLS certs not generated."
            ok=false
        fi
    else
        echo "  TLS certs already present — skipping."
    fi

    # Deploy wayvnc config with auto-generated password
    if [ ! -f /usr/local/etc/wayvnc/config ]; then
        echo "  Creating wayvnc config with random password..."
        VNC_PASS=$(head -c 10 /dev/urandom | base64 | tr -d '+/=' | head -c 10)
        cat > /usr/local/etc/wayvnc/config << WVCFG
enable_auth=true
use_relative_paths=true
password=${VNC_PASS}
WVCFG
        chmod 600 /usr/local/etc/wayvnc/config
        echo "  VNC password: ${VNC_PASS}"
        echo "  (Run 'vnc start' from within dwl, then connect with this password)"
    else
        echo "  wayvnc config already exists — skipping."
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
