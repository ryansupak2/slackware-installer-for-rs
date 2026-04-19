#!/bin/bash

# TODO set up git push (SSH?)

echo "*****************************************************"
echo "INITIALIZATION"
echo "*****************************************************"

echo "First of all, setting a reasonable Font Size..."
setfont ter-v32b

echo "Copying User Preferences..."
cp /root/slackware-installer-for-rs/dotfiles/bashrc /root/.bashrc

echo "Copying rc.font..."
cp /root/slackware-installer-for-rs/dotfiles/rc.font /etc/rc.d/rc.font
chmod +x /etc/rc.d/rc.font

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

ELILO_PATH="/boot/efi/EFI/Slackware/elilo.conf"
ELILO_PARAMS="pcie_aspm=off iwlwifi.power_save=0"

if ! grep -q "pcie_aspm=off" "$ELILO_PATH"; then
    sed -i "/append=/ s/\"$/ $ELILO_PARAMS\"/" "$ELILO_PATH"
    echo "Power Management Parameters added to $ELILO_PATH"
else
    echo "Power Management Parameters already exist in $ELILO_PATH"
fi


echo "Setting Permissions for and then Starting Network Manager..."
chmod +x /etc/rc.d/rc.networkmanager
/etc/rc.d/rc.networkmanager start
cp /root/slackware-installer-for-rs/dotfiles/rc.local /etc/rc.d/rc.local

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
echo "SBOPKG PACKAGE BROWSER"
echo "*****************************************************"

echo "Installing sbopkg from Binary..."
cd ~
wget https://github.com/sbopkg/sbopkg/releases/download/0.38.3/sbopkg-0.38.3-noarch-1_wsr.tgz 
installpkg sbopkg-0.38.3-noarch-1_wsr.tgz
rm sbopkg-0.38.3-noarch-1_wsr.tgz

echo "Syncing sbopkg to Repository..."
sbopkg -r

echo "*****************************************************"
echo "CLIPBOARD                                            "
echo "*****************************************************"

echo "Installing xclip..."
sbopkg -B -i xclip

echo "*****************************************************"
echo "VI TEXT EDITOR                                       "
echo "*****************************************************"

echo "Installing vim..."
cd ~
git clone https://github.com/vim/vim.git
cd vim
make -j$(nproc)
sudo make install

echo "Updating Config..."
cp /root/slackware-installer-for-rs/dotfiles/vimrc /root/.vimrc

echo "*****************************************************"
echo "GOOGLE CHROME                                        "
echo "*****************************************************"

echo "Installing Required Utilities..."
sbokpg -i -B alien

echo "Installing Browser..."
cd /root
wget https//dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
alien -t google-chrome-stable_current_amd64.deb

echo "*****************************************************"
echo "OPENCODE"
echo "*****************************************************"

echo "Installing OpenCode..."
curl -fsSL https://opencode.ai/install | bash

echo "Adding OpenCode to PATH..."
export PATH=/root/.opencode/bin:$PATH
cp /root/slackware-installer-for-rs/dotfiles/opencode/opencode.sh /etc/profile.d/opencode.sh
chmod +x /etc/profile.d/opencode.sh

echo "Configuring OpenCode..."
mkdir -p ~/.config/opencode
#TODO: replace keys in file with keys from memory of same name
cp /root/slackware-installer-for-rs/dotfiles/opencode/opencode.json ~/.config/opencode/opencode.json
chmod 600 ~/.config/opencode/opencode.json

mkdir -p ~/.local/share/opencode
#TODO: replace keys in file with keys from memory of same name
cp /root/slackware-installer-for-rs/dotfiles/opencode/opencode.json ~/.local/share/opencode/auth.json
chmod 600 ~/.local/share/opencode/auth.json

echo "*****************************************************"
echo "SUCKLESS DWM/DMENU/ST"
echo "*****************************************************"

mkdir -p ~/suckless
cd ~/suckless

for tool in dwm dmenu st; do
    echo "Installing Suckless ${tool}..."
    git clone https://git.suckless.org/${tool}
    cd ${tool}
    #copy out existing config file into place
    cp -f /root/slackware-installer-for-rs/dotfiles/suckless/${tool}/config.h config.h
    # Build and install (requires root for 'install' step)
    sudo make clean install
    cd ..
done

echo "Configuring startx..."
cp /root/slackware-installer-for-rs/dotfiles/.xinitrc ~/.xinitrc
