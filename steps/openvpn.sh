#!/bin/bash
# steps/openvpn.sh - OPENVPN SETUP (NordVPN, country-based configs)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "OPENVPN SETUP (NordVPN)"
echo "*****************************************************"

ok=true
if ! command -v openvpn >/dev/null 2>&1; then
    install_pkg "openvpn" || ok=false
fi

# Ensure tun device exists
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    modprobe tun 2>/dev/null || true
    mknod /dev/net/tun c 10 200 2>/dev/null || true
fi

# Add tun creation to rc.local (Slackware startup)
if [ -f /etc/rc.d/rc.local ]; then
    if ! grep -q "modprobe tun" /etc/rc.d/rc.local 2>/dev/null; then
        cat >> /etc/rc.d/rc.local << 'EOF'

# Create tun device for OpenVPN (added by post-install-global.sh)
modprobe tun 2>/dev/null || true
mkdir -p /dev/net
[ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null
EOF
    fi
fi

if $ok && [ -n "$NORD_USER" ] && [ -n "$NORD_PASS" ]; then
    mkdir -p /etc/openvpn

    # Write auth file
    cat > /etc/openvpn/nordvpn-auth.txt << AUTH
$NORD_USER
$NORD_PASS
AUTH
    chmod 600 /etc/openvpn/nordvpn-auth.txt

    # Download full OVPN config bundle from NordVPN
    echo "Downloading OpenVPN config bundle..."
    OVPN_ZIP="$REPO_DIR/ovpn.zip"
    if [ ! -f "$OVPN_ZIP" ]; then
        curl -fsSL -o "$OVPN_ZIP" https://downloads.nordcdn.com/configs/archives/servers/ovpn.zip 2>/dev/null || true
    fi
    if [ -f "$OVPN_ZIP" ]; then
        mkdir -p /etc/openvpn/configs/udp
        unzip -qo "$OVPN_ZIP" -d /etc/openvpn/configs/udp/ 2>/dev/null || true
        echo "Config bundle extracted: $(ls /etc/openvpn/configs/udp/ovpn_udp/*.ovpn 2>/dev/null | wc -l) servers"
    else
        echo "ERROR: Could not download config bundle"
        ok=false
    fi

    # Copy DNS-by-country reference file
    cp "$REPO_DIR/dotfiles/vpn/nordvpn-dns-by-country.txt" /etc/openvpn/ 2>/dev/null || true

    # Deploy OpenVPN management script
    echo "Deploying VPN management script..."
    cp "$REPO_DIR/scripts/vpn.sh" /usr/local/bin/vpn || { echo "ERROR: Failed to copy vpn script"; ok=false; }
    chmod +x /usr/local/bin/vpn 2>/dev/null || true

    # Deploy VPN suspend/resume handler (disconnect on sleep, reconnect on wake)
    echo "Deploying VPN suspend/resume handler..."
    cp "$REPO_DIR/scripts/vpn-resume.sh" /usr/local/bin/vpn-suspend 2>/dev/null || true
    chmod +x /usr/local/bin/vpn-suspend 2>/dev/null || true

    # Install elogind system-sleep hook (handles both pre-suspend and post-resume)
    if [ -d "/lib64/elogind/system-sleep" ]; then
        cat > /lib64/elogind/system-sleep/vpn-suspend.sh << 'SLEEPHOOK'
#!/bin/bash
case "$1" in
  pre)
    /usr/local/bin/vpn-suspend pre &
    ;;
  post)
    /usr/local/bin/vpn-suspend post &
    ;;
esac
SLEEPHOOK
        chmod +x /lib64/elogind/system-sleep/vpn-suspend.sh
        echo "  VPN suspend hook installed: /lib64/elogind/system-sleep/vpn-suspend.sh"
    fi

    # Deploy sudoers so wheel users can manage OpenVPN without a password prompt
    echo "Deploying sudoers for OpenVPN access..."
    mkdir -p /etc/sudoers.d
    cp "$REPO_DIR/dotfiles/sudoers/nordvpn" /etc/sudoers.d/nordvpn-wg 2>/dev/null || true
    chmod 440 /etc/sudoers.d/nordvpn-wg 2>/dev/null || true

    echo "OpenVPN setup complete."
else
    ok=false
fi

if $ok; then
    echo "SUCCESS: OpenVPN configured."
    exit 0
else
    echo "ERROR: OpenVPN setup failed."
    exit 1
fi
