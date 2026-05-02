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

    echo "Configuring Touchpad (disable tap-to-click and right-click areas)..."
    cp /root/slackware-installer-for-rs/dotfiles/70-synaptics.conf /etc/X11/xorg.conf.d/70-synaptics.conf
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

setup_vnc() {
    echo "*****************************************************"
    echo "VNC (VIRTUAL NETWORK COMPUTING)"
    echo "*****************************************************"

    echo "Installing FLTK (required library for vncviewer GUI)..."
    slackpkg -batch=on -default_answer=y install fltk || {
        echo "slackpkg failed; trying sbopkg..."
        sbopkg -B -i fltk || echo "FLTK install failed"
    }

    echo "Installing TigerVNC (client and server)..."
    slackpkg -batch=on -default_answer=y install tigervnc || {
        echo "slackpkg failed; trying sbopkg..."
        sbopkg -B -i tigervnc || echo "TigerVNC install failed"
    }

    # Copy and install VNC picker script as global command
    echo "Installing VNC picker script..."
    cp /root/slackware-installer-for-rs/dotfiles/vnc-picker.sh /usr/local/bin/vnc-picker.sh
    chmod +x /usr/local/bin/vnc-picker.sh

    echo "VNC setup complete."
    echo "Notes:"
    echo "  - Use 'vnc tv' to connect to television-computer, or 'vnc' for server menu."
    echo "  - Use 'vncviewer host:display' to connect manually (e.g., vncviewer 192.168.1.100:5901)."
    echo "  - Start server: 'vncserver :1' (sets password with 'vncpasswd' if needed)."
    echo "  - Scan network: 'nmap -p 5900-5909 192.168.1.0/24' or 'avahi-browse -r _rfb._tcp'."
    echo "  - Secure with TLS/passwords; avoid default port exposure."
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

setup_git_lfs() {
    echo "*****************************************************"
    echo "GIT LARGE FILE STORAGE (GIT LFS)"
    echo "*****************************************************"

    echo "Installing Git LFS..."
    sbopkg -B -i git-lfs

    echo "Setting up Git LFS globally..."
    git lfs install

    echo "Git LFS setup complete."
}

setup_neofetch() {
    echo "*****************************************************"
    echo "NEOFETCH                                             "
    echo "*****************************************************"

    echo "Configuring Neofetch..."
    cp /root/slackware-installer-for-rs/dotfiles/neofetch/* /root/.config/neofetch
}

setup_zoxide() {
    echo "*****************************************************"
    echo "ZOXIDE                                               "
    echo "*****************************************************"

    echo "Installing zoxide..."
    sbopkg -B -i zoxide || echo "Warning: zoxide install failed"
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

setup_yad() {
    echo "*****************************************************"
    echo "YAD (DIALOG TOOL)"
    echo "*****************************************************"

    echo "Installing yad in batch mode..."
    sbopkg -B -i yad || echo "Warning: yad install failed"
}

setup_keychain() {
    echo "*****************************************************"
    echo "KEYCHAIN (SSH AGENT MANAGER)"
    echo "*****************************************************"

    echo "Installing keychain..."
    sbopkg -B -i keychain || echo "Warning: keychain install failed"
}

setup_lxappearance() {
    echo "*****************************************************"
    echo "LXAPPEARANCE (GTK THEME MANAGER)"
    echo "*****************************************************"

    echo "Installing lxappearance in batch mode..."
    sbopkg -B -i lxappearance || echo "Warning: lxappearance install failed"
}

setup_gtk_prefs() {
    echo "*****************************************************"
    echo "GTK PREFERENCES"
    echo "*****************************************************"

    echo "Applying GTK preferences after fonts..."
    # Ensure lxappearance is available (though installed earlier)
    if ! command -v lxappearance >/dev/null 2>&1; then
        echo "Error: lxappearance not found, skipping GTK prefs"
        return 1
    fi
    # Copy to /etc/skel for new users
    mkdir -p /etc/skel/.config/gtk-3.0
    if [ -f /root/slackware-installer-for-rs/dotfiles/gtk/.gtkrc-2.0 ]; then
        cp /root/slackware-installer-for-rs/dotfiles/gtk/.gtkrc-2.0 /etc/skel/.gtkrc-2.0
    else
        echo "Warning: /root/slackware-installer-for-rs/dotfiles/gtk/.gtkrc-2.0 not found, skipping GTK2 prefs"
    fi
    if [ -f /root/slackware-installer-for-rs/dotfiles/gtk/settings.ini ]; then
        cp /root/slackware-installer-for-rs/dotfiles/gtk/settings.ini /etc/skel/.config/gtk-3.0/settings.ini
    else
        echo "Warning: /root/slackware-installer-for-rs/dotfiles/gtk/settings.ini not found, skipping GTK3 prefs"
    fi
    # Apply immediately to root (current user)
    mkdir -p ~/.config/gtk-3.0
    cp /etc/skel/.gtkrc-2.0 ~/.gtkrc-2.0 2>/dev/null || true
    cp /etc/skel/.config/gtk-3.0/settings.ini ~/.config/gtk-3.0/settings.ini 2>/dev/null || true
    # Force GTK to reload settings
    gtk-query-immodules-2.0 --update-cache 2>/dev/null || true
    gtk-query-immodules-3.0 --update-cache 2>/dev/null || true
    echo "GTK preferences applied globally and to root"
}

setup_chromium() {
    echo "*****************************************************"
    echo "CHROMIUM                                             "
    echo "*****************************************************"

    echo "Installing Browser..."
    cd /tmp
    wget https://slackware.nl/people/alien/slackbuilds/chromium/pkg64/15.0/chromium-147.0.7727.116-x86_64-1alien.txz
    installpkg chromium-147.0.7727.116-x86_64-1alien.txz
    rm chromium-147.0.7727.116-x86_64-1alien.txz

    echo "Installing Widevine CDM for DRM support..."
    cd /tmp
    wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    ar x google-chrome-stable_current_amd64.deb
    tar -xf data.tar.xz
    mkdir -p /usr/lib64/chromium/WidevineCdm/_platform_specific/linux_x64/
    cp opt/google/chrome/WidevineCdm/_platform_specific/linux_x64/libwidevinecdm.so /usr/lib64/chromium/WidevineCdm/_platform_specific/linux_x64/
    cp opt/google/chrome/WidevineCdm/manifest.json /usr/lib64/chromium/WidevineCdm/
    chmod 755 /usr/lib64/chromium/WidevineCdm/_platform_specific/linux_x64/libwidevinecdm.so
    rm -rf google-chrome-stable_current_amd64.deb data.tar.xz control.tar.xz debian-binary opt
    echo "Widevine CDM installed."

    echo "Installing xdg-desktop-portal-gtk..."
    sbopkg -B -i xdg-desktop-portal-gtk

    echo "Installing yad..."
    sbopkg -B -i yad

    echo "Copying Chromium wrapper script..."
    mkdir -p /usr/local/bin
    cp /root/slackware-installer-for-rs/dotfiles/chromium/chromium-wrapper.sh /usr/local/bin/chromium-wrapper.sh
    chmod +x /usr/local/bin/chromium-wrapper.sh
}

setup_nordvpn() {
    echo "*****************************************************"
    echo "NORDVPN SETUP                                       "
    echo "*****************************************************"

    echo "Building NordVPN package..."
    sbopkg -b nordvpn

    echo "Modifying doinst.sh to avoid hanging restart..."
    # Comment out the automatic restart in doinst.sh to prevent installation hangs or failures
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
        cp /root/slackware-installer-for-rs/dotfiles/vpn/nordvpn-run.sh /usr/local/bin/
        chmod 755 /usr/local/bin/nordvpn-run.sh
        # Replace the default rc.nordvpn from the NordVPN package with a custom version that uses 'pgrep' for reliable process detection (instead of PID file checks), includes improved error handling (e.g., terminating failed daemon starts and better logging), and ensures better Slackware compatibility.
        cp /root/slackware-installer-for-rs/dotfiles/vpn/rc.nordvpn /etc/rc.d/rc.nordvpn
    fi
}

setup_opencode() {
    echo "*****************************************************"
    echo "OPENCODE"
    echo "*****************************************************"

    echo "Installing OpenCode..."
    curl -fsSL https://opencode.ai/install | bash
}

setup_llm() {
    echo "*****************************************************"
    echo "LLM (LANGUAGE MODEL CLI)"
    echo "*****************************************************"

    echo "Installing llm via pip..."
    pip3 install llm

    echo "Installing llm-grok plugin..."
    llm install llm-grok

    echo "Setting up Grok API key..."
    llm keys set grok --value "$XAI_API_KEY_CHAT"

    echo "Setting default model to grok-4-1-fast..."
    llm models default grok-4-1-fast

    echo "Copying modified llm_grok plugin..."
    cp /root/slackware-installer-for-rs/dotfiles/llm/llm_grok.py /usr/lib64/python3.9/site-packages/llm_grok.py

    echo "Copying llm wrapper script..."
    cp /root/slackware-installer-for-rs/dotfiles/llm/llm-wrapper.sh /usr/local/bin/llm-wrapper.sh
    chmod +x /usr/local/bin/llm-wrapper.sh

    echo "Copying llm system prompt..."
    cp /root/slackware-installer-for-rs/dotfiles/llm/llm-system-prompt ~/.llm-system-prompt

    echo "LLM setup complete."
}

setup_xinitrc() {
    echo "*****************************************************"
    echo "XINITRC                                              "
    echo "*****************************************************"

    cd ~
    cp /root/slackware-installer-for-rs/dotfiles/xinitrc /root/.xinitrc
    chmod +x /root/.xinitrc

    cp /root/slackware-installer-for-rs/dotfiles/bashrc ~/.bashrc
}

setup_help() {
    echo "*****************************************************"
    echo "HELP SCRIPT"
    echo "*****************************************************"

    echo "Copying help script..."
    cp /root/slackware-installer-for-rs/dotfiles/help.sh /usr/local/bin/
    chmod +x /usr/local/bin/help.sh
}

setup_suckless() {
    echo "*****************************************************"
    echo "SUCKLESS DWM/ST"
    echo "*****************************************************"

    mkdir -p ~/suckless
    cd ~/suckless

    for tool in dwm st; do
        echo "Installing Suckless ${tool}..."
        git clone https://git.suckless.org/${tool}
        cd ${tool}
        # Copy out existing config file into place
        cp -f /root/slackware-installer-for-rs/dotfiles/suckless/${tool}/config.h config.h
        # For dwm, also copy the modified dwm.c
        if [ "${tool}" = "dwm" ]; then
            cp -f /root/slackware-installer-for-rs/dotfiles/suckless/dwm/dwm.c dwm.c
        fi
        # For st, copy the patched source files
        if [ "${tool}" = "st" ]; then
            cp /root/slackware-installer-for-rs/dotfiles/suckless/st/st.c st.c
            cp /root/slackware-installer-for-rs/dotfiles/suckless/st/st.h st.h
            cp /root/suckless/st/config.def.h config.def.h
        fi
        # Build and install (requires root for 'install' step)
        sudo make clean install
        cd ..
    done
}

# Category definitions
system_infra=("Networking and WiFi" "Input Hardware" "Packaging and Security" "Sbopkg Setup")
hardware_config=("Screen Locking" "Audio/Volume" "Brightness" "Clipboard (xclip)")
security_access=("Keychain" "NordVPN")
dev_tools=("VNC" "Vim Editor" "Git LFS" "OpenCode" "LLM")
ui_appearance=("Neofetch" "Additional Fonts" "Yad (dialog tool)" "Lxappearance (GTK theme manager)" "GTK Preferences" "Xinitrc" "Suckless (dwm/dmenu/st)")
applications=("Chromium")
utilities=("Help Script" "Zoxide")

categories=("System Infrastructure" "Hardware Configuration" "Security & Access" "Development Tools" "User Interface & Appearance" "Applications" "Utilities")

# Flatten all options for non-interactive and case statement
options=("${system_infra[@]}" "${hardware_config[@]}" "${security_access[@]}" "${dev_tools[@]}" "${ui_appearance[@]}" "${applications[@]}" "${utilities[@]}")

# Interactive menu
if $INTERACTIVE; then
    echo "Select categories and items to run. You can select from multiple categories."
    selected=()

    while true; do
        echo "Available categories:"
        for i in "${!categories[@]}"; do
            echo "$((i+1)). ${categories[$i]}"
        done
        echo "$(( ${#categories[@]} + 1 )). All sections"
        echo "$(( ${#categories[@]} + 2 )). Exit"

        read -p "Enter category number, 'all' for everything, or 'done' to proceed: " cat_choice
        case $cat_choice in
            all|All|ALL|$(( ${#categories[@]} + 1 )))
                selected=("${options[@]}")
                break
                ;;
            exit|Exit|EXIT|$(( ${#categories[@]} + 2 )))
                exit 0
                ;;
            done|Done|DONE)
                break
                ;;
            [1-9]|10)
                cat_index=$((cat_choice - 1))
                if [ $cat_index -ge 0 ] && [ $cat_index -lt ${#categories[@]} ]; then
                    category="${categories[$cat_index]}"
                    # Get submenu array
                    case $category in
                        "System Infrastructure") submenu=("${system_infra[@]}") ;;
                        "Hardware Configuration") submenu=("${hardware_config[@]}") ;;
                        "Security & Access") submenu=("${security_access[@]}") ;;
                        "Development Tools") submenu=("${dev_tools[@]}") ;;
                        "User Interface & Appearance") submenu=("${ui_appearance[@]}") ;;
                        "Applications") submenu=("${applications[@]}") ;;
                        "Utilities") submenu=("${utilities[@]}") ;;
                    esac

                    echo "Select items in $category (numbers separated by commas, 'all' for category, 'back' to return):"
                    echo "Available items:"
                    for i in "${!submenu[@]}"; do
                        echo "$((i+1)). ${submenu[$i]}"
                    done
                    echo "$(( ${#submenu[@]} + 1 )). All in $category"
                    echo "$(( ${#submenu[@]} + 2 )). Back"

                    read -p "Enter your choice: " item_choice
                    case $item_choice in
                        all|All|ALL|$(( ${#submenu[@]} + 1 )))
                            for item in "${submenu[@]}"; do
                                selected+=("$item")
                            done
                            ;;
                        back|Back|BACK|$(( ${#submenu[@]} + 2 )))
                            ;;
                        [0-9]*,*[0-9]*)
                            IFS=',' read -ra nums <<< "$item_choice"
                            for num in "${nums[@]}"; do
                                if [ $num -ge 1 ] && [ $num -le ${#submenu[@]} ]; then
                                    selected+=("${submenu[$((num-1))]}")
                                fi
                            done
                            ;;
                        [1-9]|1[0-9]|2[0-9])
                            num=$((item_choice-1))
                            selected+=("${submenu[$num]}")
                            ;;
                        *)
                            echo "Invalid choice. Try again."
                            ;;
                    esac
                else
                    echo "Invalid category. Try again."
                fi
                ;;
            *)
                echo "Invalid choice. Try again."
                ;;
        esac

        if [ ${#selected[@]} -gt 0 ]; then
            echo "Selected so far: ${selected[*]}"
        fi
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
        "VNC") setup_vnc ;;
        "Vim Editor") setup_vim ;;
        "Git LFS") setup_git_lfs ;;
        "Neofetch") setup_neofetch ;;
        "Additional Fonts") setup_fonts ;;
        "Yad (dialog tool)") setup_yad ;;
        "Keychain") setup_keychain ;;
        "Lxappearance (GTK theme manager)") setup_lxappearance ;;
        "GTK Preferences") setup_gtk_prefs ;;
        "Chromium") setup_chromium ;;
        "NordVPN") setup_nordvpn ;;
        "OpenCode") setup_opencode ;;
        "LLM") setup_llm ;;
        "Xinitrc") setup_xinitrc ;;
        "Help Script") setup_help ;;
        "Suckless (dwm/st)") setup_suckless ;;
    esac
done

echo "Global setup complete. Run post-install-user.sh for per-user configs."
rsync -av --exclude=setup.keys /root/slackware-installer-for-rs/ /usr/local/share/slackware-installer-for-rs/
