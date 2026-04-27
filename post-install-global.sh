#!/bin/bash

# post-install-global.sh - Global system setup for Slackware installer
# Run once as root after ISO install.

# TODO: fix audio recording

if [ "$1" = "--help" ]; then
    echo "Usage: ./post-install-global.sh"
    echo "Performs global system setup: installs packages, configures networking/hardware, builds tools."
    echo "Must be run as root. Run post-install-user.sh afterward for per-user configs."
    exit 0
fi

echo "*****************************************************"
echo "INITIALIZATION"
echo "*****************************************************"

echo "First of all, setting a reasonable Font Size..."
setfont ter-v32b

echo "Copying rc.font to make font change permanent..."
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
echo "INPUT HARDWARE                                       "
echo "*****************************************************"

echo "Disabling Touchscreen..."
cp /root/slackware-installer-for-rs/dotfiles/99-disable-touchscreen.conf /etc/X11/xorg.conf.d/99-disable-touchscreen.conf

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
echo "SCREEN LOCKING                                       "
echo "*****************************************************"

echo "Configuring Hardware to Lock on Laptop Reopen..."

cp ~/slackware-installer-for-rs/dotfiles/lockscreen/lid-close /etc/acpi/events/lid-close
cp ~/slackware-installer-for-rs/dotfiles/lockscreen/lock-screen.sh /usr/local/bin/lock-screen.sh
chmod +x /usr/local/bin/lock-screen.sh
/etc/rc.d/rc.acpid restart

echo "Configuring xlock preferences..."
cd ~
cp /root-slackware-installer-for-rs/dotfiles/xdefaults ~/.Xdefaults
xrdb merge ~/.Xdefaults

echo "*****************************************************"
echo "AUDIO/VOLUME					   "
echo "*****************************************************"

echo "Copying Volume Scripts..."
cd ~
sudo cp /root/slackware-installer-for-rs/dotfiles/volume/* /usr/local/bin/
sudo chmod 755 /usr/local/bin/volume_*.sh

echo "*****************************************************"
echo "BRIGHTNESS (MONITOR AND KEYBOARD)                    "
echo "*****************************************************"

cd ~
sudo cp /root/slackware-installer-for-rs/dotfiles/brightness/* /usr/local/bin/
sudo chmod 755 /usr/local/bin/brightness_*.sh

sudo cp /root/slackware-installer-for-rs/dotfiles/kbd_backlight/* /usr/local/bin/
sudo chmod 755 /usr/local/bin/kbd_backlight_*.sh

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
rm -rf vim

echo "*****************************************************"
echo "NEOFETCH                                             "
echo "*****************************************************"

echo "Configuring Neofetch..."
cp /root/slackware_installer_for_rs/dotfiles/neofetch/* /root/.config/neofetch

echo "*****************************************************"
echo "ADDITIONAL FONTS                                     "
echo "*****************************************************"

echo "Installing Additional Fonts..."
mkdir -p /usr/share/fonts/TTF
cp ~/slackware/installer-for-rs/fonts/BerkeleyMono-*.ttf /usr/share/fonts/TTF/
fc-cache -fv

echo "*****************************************************"
echo "GOOGLE CHROME                                        "
echo "*****************************************************"

echo "Installing Required Utilities..."
sbokpg -i -B alien

echo "Installing Browser..."
cd /root
wget https//dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
alien -t google-chrome-stable_current_amd64.deb
rm https//dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
rm google-chrome-stable-147.0.7727.101-x86_64-1_alien.tgz

echo "*****************************************************"
echo "OPENCODE"
echo "*****************************************************"

echo "Installing OpenCode..."
curl -fsSL https://opencode.ai/install | bash

echo "*****************************************************"
echo "INKSCAPE (disabled by default)"
echo "*****************************************************"

# Inkscape install (specifically the final inkscape part) is a bit time-consuming so it is disabled by default.
# It is included here mostly for reference though in practice it may make sense to do these steps manually:

# echo "Installing PreReqs (should be quick)..."
# sbopkg -B -i dos2unix
# sbopkg -B -i double-conversion
# sbopkg -B -i potrace

# echo "Installing Inkscape (this takes a while)..."
# sbopkg -B -i inkscape

echo "*****************************************************"
echo "XINITRC                                              "
echo "*****************************************************"

cd ~
cp /root/slackware-installer-for-rs/dotfiles/xinitrc /root/.xinitrc
chmod +x /root/.xinitrc

echo "*****************************************************"
echo "SUCKLESS DWM/DMENU/ST"
echo "*****************************************************"

mkdir -p ~/suckless
cd ~/suckless

for tool in dwm dmenu st; do
    echo "Installing Suckless ${tool}..."
    git clone https://git.suckless.org/${tool}
    cd ${tool}
    # Copy out existing config file into place
    cp -f /root/slackware-installer-for-rs/dotfiles/suckless/${tool}/config.h config.h
    # For dwm, also copy the modified dwm.c
    if [ "${tool}" = "dwm" ]; then
        cp -f /root/slackware-installer-for-rs/dotfiles/suckless/dwm/dwm.c dwm.c
    fi
    # Build and install (requires root for 'install' step)
    sudo make clean install
    cd ..
done

echo "Global setup complete. Run post-install-user.sh for per-user configs."
