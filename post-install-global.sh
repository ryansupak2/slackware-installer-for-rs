#!/bin/bash

# post-install-global.sh - Global system setup for Slackware installer
# Run once as root after ISO install.

# TODO: alter dwm to control screen brightness with Fn+F5 anf Fn+F6
# echo 24242 > /sys/class/backlight/intel_backlight/brightness
#
# TODO: alter dwm to control audio volume with Fn+F1, Fn+F2, and Fn+F3
# TODO: alter dwm to control keyboard brightness with Shift+Fn+F5 and Shift+Fn+F6
# echo 0 > /sys/class/leds/tpacpi::kbd_backlight/brightness

# TODO: alter dwm to disable all other Fn+F combinations

# TODO: alter dwm to show Brightness, Kbd Light, Volume for 2 seconds, replacing BAT and Date but not Time

# TODO: add slock, others to get Password Lockout on Wake

# TODO: put Berkeley Mono font in github
# sudo mkdir -p /usr/local/share/fonts/TTF
# root@TX-02-YLJR4PM5# cp * /usr/local/share/fonts/TTF
#  sudo fc-cache -fv
#  fc-list | grep "Berk"

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
