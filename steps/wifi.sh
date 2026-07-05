#!/bin/bash
# steps/wifi.sh - NETWORKING / WiFi (NetworkManager + nmcli)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "NETWORKING"
echo "*****************************************************"

# 1. Detect WiFi card
WLAN_IF=$(iw dev 2>/dev/null | awk '$1 == "Interface" { print $2; exit }' || true)
if [ -z "$WLAN_IF" ]; then
    WLAN_IF=$(ls /sys/class/net/ 2>/dev/null | grep -E '^(wlan|wlp|wlo)' | head -1 || true)
fi
if [ -n "$WLAN_IF" ] && [ -d "/sys/class/net/$WLAN_IF" ]; then
    echo "Found WiFi card: $WLAN_IF"
else
    echo "No WiFi card found."
    WLAN_IF=""
fi

# 2. Power management settings
echo "Copying WiFi Power Management Settings..."
cp "$REPO_DIR/dotfiles/configs/wifi-powersave-off.conf" /etc/NetworkManager/conf.d/wifi-powersave-off.conf 2>/dev/null || true
chmod 600 /etc/NetworkManager/conf.d/wifi-powersave-off.conf 2>/dev/null || true
cp "$REPO_DIR/dotfiles/configs/iwlwifi.conf" /etc/modprobe.d/iwlwifi.conf 2>/dev/null || true
chmod 600 /etc/modprobe.d/iwlwifi.conf 2>/dev/null || true

# Kernel cmdline params (elilo)
ELILO_PATH="/boot/efi/EFI/Slackware/elilo.conf"
ELILO_PARAMS="pcie_aspm=off iwlwifi.power_save=0 i915.fastboot=1 i915.enable_psr=0"
if [ -f "$ELILO_PATH" ]; then
    if ! grep -q "pcie_aspm=off" "$ELILO_PATH" 2>/dev/null; then
        sed -i "/append=/ s/\"$/ $ELILO_PARAMS\"/" "$ELILO_PATH"
        echo "Power Management Parameters added to $ELILO_PATH"
    fi
elif [ -f /etc/default/grub ]; then
    if ! grep -q "pcie_aspm=off" /etc/default/grub 2>/dev/null; then
        sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $ELILO_PARAMS\"|" /etc/default/grub
        grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
    fi
fi

# 3. Start NetworkManager
echo "Enabling and starting NetworkManager..."
chmod +x /etc/rc.d/rc.networkmanager 2>/dev/null || true
/etc/rc.d/rc.networkmanager start 2>/dev/null || true

# 4. Ensure rc.local exists and starts NetworkManager (append, never overwrite)
if [ ! -f /etc/rc.d/rc.local ]; then
    cp "$REPO_DIR/dotfiles/system/rc.local" /etc/rc.d/rc.local 2>/dev/null || true
else
    if ! grep -q "rc.networkmanager start" /etc/rc.d/rc.local 2>/dev/null; then
        echo "/etc/rc.d/rc.networkmanager start" >> /etc/rc.d/rc.local
        echo "  Added NetworkManager start to rc.local"
    else
        echo "  NetworkManager already in rc.local"
    fi
fi
chmod +x /etc/rc.d/rc.local 2>/dev/null || true

# 5. Connect to WiFi if keys provided
if [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PASS" ]; then
    echo "Configuring WiFi for $WIFI_SSID..."
    sleep 2  # Give NetworkManager time to start
    nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASS" name "$WIFI_SSID" 2>/dev/null || true
    nmcli connection modify "$WIFI_SSID" connection.autoconnect yes 2>/dev/null || true
    echo "SUCCESS: WiFi configured for auto-reconnect on reboot (NetworkManager)."
else
    echo "Missing connection keys (WIFI_SSID or WIFI_PASS) in setup.keys.root"
    echo "WiFi not auto-configured; use nmtui or nmcli manually."
fi

exit 0
