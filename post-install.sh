#!/bin/bash

echo "*****************************************************"
echo "INITIALIZATION"
echo "*****************************************************"

echo "First of all, setting a reasonable Font Size..."
setfont ter-v32b

echo "Copying rc.font..."
cp /root/slackware-installer-for-rs/dotfiles/rc.font /etc/rc.d/rc.font
chmod 600 /etc/rc.d/rc.font

echo "Reading Keys from setup.keys..."
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" =~ ^# ]] && continue
  export "$key"="$value"
done < "$KEY_FILE"

echo "*****************************************************"
echo "NETWORKING AND WIFI"
echo "*****************************************************"

echo "Copying Wifi Power Management Settings (to prevent random WiFi dropouts)..."
cp /root/slackware-installer-for-rs/dotfiles/wifi-powersave-off.conf /etc/NetworkManager/conf.d/wifi-powersave-off.conf 
chmod 600 /etc/NetworkManager/conf.d/wifi-powersave-off.conf
cp /root/slackware-installer-for-rs/dotfiles/iwlwifi.conf /etc/modprobe.d/iwlwifi.conf
chmod 600 /etc/modprobe.d/iwlwifi.conf

echo "Setting Permissions for and then Starting Network Manager..."
chmod +x /etc/rc.d/rc.networkmanager
/etc/rc.d/rc.networkmanager start

echo "Configuring WiFi for $WIFI_SSID..."
nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASS" name "$WIFI_SSID"
nmcli connection modify "$WIFI_SSID" connection.autoconnect yes

echo "*****************************************************"
echo "PACKAGING AND RELATED SECURITY"
echo "*****************************************************"

echo "Fixing package manager GPG issue by removing then reinstalling latest of gnupg2..."
slackpkg -batch=on -default_answer=y remove gnupg2
slackpkg -batch=on -default_answer=y install gnupg2

echo "Setting mirror (to most reliable)..."
sed -i 's|^#http://mirrors.slackware.com/slackware/slackware64-15.0/|http://mirrors.slackware.com/slackware/slackware64-15.0/|' /etc/slackpkg/mirrors

echo "Fixing HTTPS/SSL so that git (among others) will work..."
update-ca-certificates --fresh
ln -sf /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-bundle.crt

echo "*****************************************************"
echo "OPENCODE"
echo "*****************************************************"

echo "Installing OpenCode..."
curl -fsSL https://opencode.ai/install | bash
export PATH=/root/.opencode/bin:$PATH

echo "Configuring OpenCode..."
mkdir -p ~/.config/opencode
#TODO: replace keys in file with keys from memory of same name
cp /root/slackware-installer-for-rs/dotfiles/opencode/opencode.json ~/.config/opencode/opencode.json
chmod 600 ~/.config/opencode/opencode.json

mkdir -p ~/.local/share/opencode
#TODO: replace keys in file with keys from memory of same name
cp /root/slackware-installer-for-rs/dotfiles/opencode/opencode.json ~/.local/share/opencode/auth.json
chmod 600 ~/.local/share/opencode/auth.json
