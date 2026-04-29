#!/bin/bash

# post-install-global.sh - Global system setup for Slackware installer
# Run once as root after ISO install.
# Interactive menu by default; use --non-interactive for full run.

# TODO: fix audio recording

# TODO: fix user issues
#	- backlight
#	- chrome
#	- vpn
#	- more...

# Argument parsing
INTERACTIVE=true
while [[ $# -gt 0 ]]; do
    case $1 in
        --non-interactive|--all)
            INTERACTIVE=false
            ;;
        --help)
            echo "Usage: $0 [--non-interactive|--all] [--help]"
            echo "Interactive menu by default; --non-interactive runs all sections."
            echo "Must be run as root. Run post-install-user.sh afterward for per-user configs."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

# Global setup (always run)
echo "*****************************************************"
echo "INITIALIZATION"
echo "*****************************************************"

echo "First of all, setting a reasonable Font Size..."
setfont ter-v32b

echo "Copying rc.font to make font change permanent..."
cp /root/slackware-installer-for-rs/dotfiles/rc.font /etc/rc.d/rc.font
chmod +x /etc/rc.d/rc.font

echo "Reading Keys from setup.keys..."
KEY_FILE="/root/slackware-installer-for-rs/setup.keys"
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" =~ ^# ]] && continue
  export "$key"="$value"
done < "$KEY_FILE"

# Function definitions
setup_networking() {
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
}

setup_input() {
    echo "*****************************************************"
    echo "INPUT HARDWARE                                       "
    echo "*****************************************************"

    echo "Disabling Touchscreen..."
    cp /root/slackware-installer-for-rs/dotfiles/99-disable-touchscreen.conf /etc/X11/xorg.conf.d/99-disable-touchscreen.conf
}

setup_packaging() {
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
}

setup_sbopkg() {
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
}

setup_locking() {
    echo "*****************************************************"
    echo "SCREEN LOCKING                                       "
    echo "*****************************************************"

    echo "Configuring Hardware to Lock on Laptop Reopen..."

    cp ~/slackware-installer-for-rs/dotfiles/lockscreen/lid-close /etc/acpi/events/lid-close
    cp ~/slackware-installer-for-rs/dotfiles/lockscreen/lock-screen.sh /usr/local/bin/lock-screen.sh
    cp ~/slackware-installer-for-rs/dotfiles/lockscreen/lid-timer.sh /usr/local/bin/lid-timer.sh

    chmod +x /usr/local/bin/lock-screen.sh
    /etc/rc.d/rc.acpid restart

    echo "Configuring xlock preferences..."
    cd ~
    cp /root/slackware-installer-for-rs/dotfiles/xdefaults ~/.Xdefaults
    xrdb merge ~/.Xdefaults
}

setup_audio() {
    echo "*****************************************************"
    echo "AUDIO/VOLUME					   "
    echo "*****************************************************"

    echo "Copying Volume Scripts..."
    cd ~
    sudo cp /root/slackware-installer-for-rs/dotfiles/volume/* /usr/local/bin/
    sudo chmod 755 /usr/local/bin/volume_*.sh
}

setup_brightness() {
    echo "*****************************************************"
    echo "BRIGHTNESS (MONITOR AND KEYBOARD)                    "
    echo "*****************************************************"

    cd ~
    sudo cp /root/slackware-installer-for-rs/dotfiles/brightness/* /usr/local/bin/
    sudo chmod 755 /usr/local/bin/brightness_*.sh

    sudo cp /root/slackware-installer-for-rs/dotfiles/kbd_backlight/* /usr/local/bin/
    sudo chmod 755 /usr/local/bin/kbd_backlight_*.sh

    echo "Setting up keyboard backlight permissions..."
    sudo cp /root/slackware-installer-for-rs/dotfiles/udev/90-keyboard-backlight.rules /etc/udev/rules.d/
    sudo udevadm control --reload-rules
    sudo udevadm trigger --subsystem-match=leds
}

setup_clipboard() {
    echo "*****************************************************"
    echo "CLIPBOARD                                            "
    echo "*****************************************************"

    echo "Installing xclip..."
    sbopkg -B -i xclip
}

setup_vim() {
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
}

setup_neofetch() {
    echo "*****************************************************"
    echo "NEOFETCH                                             "
    echo "*****************************************************"

    echo "Configuring Neofetch..."
    cp /root/slackware-installer-for-rs/dotfiles/neofetch/* /root/.config/neofetch
}

setup_fonts() {
    echo "*****************************************************"
    echo "ADDITIONAL FONTS                                     "
    echo "*****************************************************"

    echo "Installing Additional Fonts..."
    mkdir -p /usr/share/fonts/TTF
    cp ~/slackware-installer-for-rs/fonts/BerkeleyMono-*.ttf /usr/share/fonts/TTF/
    fc-cache -fv
}

setup_chrome() {
    echo "*****************************************************"
    echo "GOOGLE CHROME                                        "
    echo "*****************************************************"

    echo "Installing Required Utilities..."
    sbopkg -i -B alien

    echo "Installing Browser..."
    cd /root
    wget https//dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    alien -t google-chrome-stable_current_amd64.deb
    rm https//dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    rm google-chrome-stable-147.0.7727.101-x86_64-1_alien.tgz
}

setup_nordvpn() {
    echo "*****************************************************"
    echo "NORDVPN SETUP                                       "
    echo "*****************************************************"

    echo "Building NordVPN package..."
    sbopkg -b nordvpn

    echo "Modifying doinst.sh to avoid hanging restart..."
    PKG_FILE=$(find /tmp -name "nordvpn-*.tgz" | head -1)
    if [ -z "$PKG_FILE" ]; then
        echo "NordVPN package not found. Skipping NordVPN setup."
    else
        mkdir -p /tmp/nordvpn_install
        cd /tmp/nordvpn_install
        tar -xzf "$PKG_FILE"
        sed -i 's|/etc/rc.d/rc.nordvpn restart > /dev/null|# /etc/rc.d/rc.nordvpn restart > /dev/null|' install/doinst.sh
        tar -czf /tmp/nordvpn-fixed.tgz .
        cd /
        rm -rf /tmp/nordvpn_install

        echo "Installing modified NordVPN package..."
        installpkg /tmp/nordvpn-fixed.tgz
        rm /tmp/nordvpn-fixed.tgz "$PKG_FILE"

        # Enable NordVPN service (but do not start automatically)
        chmod +x /etc/rc.d/rc.nordvpn

        # Login (use token for 2FA; token from setup.keys) - service will start when needed
        if [ -n "$NORD_TOKEN" ]; then
            nordvpn login --token "$NORD_TOKEN"
        else
            echo "NordVPN token not found in setup.keys. Run 'nordvpn login' manually."
        fi

        echo "NordVPN setup complete (service starts on demand)."

        # Install NordVPN management script
        mkdir -p /usr/local/bin
        cp /root/slackware-installer-for-rs/dotfiles/nordvpn-run.sh /usr/local/bin/
        chmod 755 /usr/local/bin/nordvpn-run.sh
    fi
}

setup_opencode() {
    echo "*****************************************************"
    echo "OPENCODE"
    echo "*****************************************************"

    echo "Installing OpenCode..."
    curl -fsSL https://opencode.ai/install | bash
}

setup_xinitrc() {
    echo "*****************************************************"
    echo "XINITRC                                              "
    echo "*****************************************************"

    cd ~
    cp /root/slackware-installer-for-rs/dotfiles/xinitrc /root/.xinitrc
    chmod +x /root/.xinitrc
}

setup_suckless() {
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
        # For dmenu, also copy the modified dmenu_run
        if [ "${tool}" = "dmenu" ]; then
            cp -f /root/slackware-installer-for-rs/dotfiles/suckless/dmenu/dmenu_run dmenu_run
        fi
        # Build and install (requires root for 'install' step)
        sudo make clean install
        cd ..
    done
}

# Interactive menu
if $INTERACTIVE; then
    echo "Select sections to run (enter numbers separated by commas, or 'all' for everything, 'exit' to quit):"
    options=("Networking and WiFi" "Input Hardware" "Packaging and Security" "Sbopkg Setup" "Screen Locking" "Audio/Volume" "Brightness" "Clipboard (xclip)" "Vim Editor" "Neofetch" "Additional Fonts" "Google Chrome" "NordVPN" "OpenCode" "Xinitrc" "Suckless (dwm/dmenu/st)")
    selected=()

    PS3="Enter your choice (or 'done' to proceed): "
    while true; do
        echo "Available sections:"
        for i in "${!options[@]}"; do
            echo "$((i+1)). ${options[$i]}"
        done
        echo "17. All"
        echo "18. Exit"

        read -p "$PS3" choice
        case $choice in
            all|All|ALL|17)
                selected=("${options[@]}")
                break
                ;;
            exit|Exit|EXIT|18)
                exit 0
                ;;
            done|Done|DONE)
                break
                ;;
            [0-9]*,*[0-9]*)
                IFS=',' read -ra nums <<< "$choice"
                for num in "${nums[@]}"; do
                    if [ "$num" = "17" ]; then
                        selected=("${options[@]}")
                        break 2
                    elif [ "$num" = "18" ]; then
                        exit 0
                    elif [ $num -ge 1 ] && [ $num -le ${#options[@]} ]; then
                        selected+=("${options[$((num-1))]}")
                    fi
                done
                ;;
        [1-9]|1[0-6])
            num=$((choice-1))
            selected+=("${options[$num]}")
            break
            ;;
            *)
                echo "Invalid choice. Try again."
                ;;
        esac
    done

    if [ ${#selected[@]} -eq 0 ]; then
        echo "No sections selected. Exiting."
        exit 0
    fi

    echo "Selected sections: ${selected[*]}"
    read -p "Proceed with these sections? (y/N): " confirm
    [[ "$confirm" != [yY] ]] && exit 0
else
    selected=("${options[@]}")
fi

# Execute selected functions
for section in "${selected[@]}"; do
    case $section in
        "Networking and WiFi") setup_networking ;;
        "Input Hardware") setup_input ;;
        "Packaging and Security") setup_packaging ;;
        "Sbopkg Setup") setup_sbopkg ;;
        "Screen Locking") setup_locking ;;
        "Audio/Volume") setup_audio ;;
        "Brightness") setup_brightness ;;
        "Clipboard (xclip)") setup_clipboard ;;
        "Vim Editor") setup_vim ;;
        "Neofetch") setup_neofetch ;;
        "Additional Fonts") setup_fonts ;;
        "Google Chrome") setup_chrome ;;
        "NordVPN") setup_nordvpn ;;
        "OpenCode") setup_opencode ;;
        "Xinitrc") setup_xinitrc ;;
        "Suckless (dwm/dmenu/st)") setup_suckless ;;
    esac
done

echo "Global setup complete. Run post-install-user.sh for per-user configs."
rsync -av --exclude=setup.keys /root/slackware-installer-for-rs/ /usr/local/share/slackware-installer-for-rs/
