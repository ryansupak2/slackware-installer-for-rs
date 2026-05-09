#!/bin/sh

# freebsd-post-install-global.sh - Global system setup for FreeBSD installer
# Run once as root after ISO install.
# Interactive menu by default; use --non-interactive for full run.

# TODO: intermittent VPN fix
# TODO: st a little less wide than chromium

# Argument parsing
INTERACTIVE=true
while [ $# -gt 0 ]; do
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

# Install bash if not present
if ! command -v bash >/dev/null 2>&1; then
    echo "Installing bash..."
    pkg update
    pkg install -y bash
fi

echo "First of all, setting a reasonable Font Size..."
vidcontrol -f 8x16 ter-v16b  # FreeBSD console font command

echo "Configuring DBus connection limits..."
cp /root/freebsd-installer-for-rs/dotfiles/dbus/system-local.conf /usr/local/etc/dbus-1/system-local.conf
service dbus restart

echo "Reading Keys from setup.keys..."
KEY_FILE="/root/freebsd-installer-for-rs/setup.keys"
while IFS='=' read -r key value; do
    case $key in
        ''|'#'*) continue ;;
    esac
    export "$key=$value"
done < "$KEY_FILE"

# Function definitions
setup_networking() {
    echo "*****************************************************"
    echo "NETWORKING AND WIFI"
    echo "*****************************************************"

    # Check if WiFi is already connected (from installer)
    if ifconfig wlan0 2>/dev/null | grep -q "status: associated"; then
        echo "WiFi already connected. Skipping connection setup."
    else
        echo "Configuring WiFi for $WIFI_SSID..."
        # FreeBSD WiFi setup: create wlan interface if needed, use wpa_supplicant
        ifconfig wlan0 create wlandev ath0  # Example for Atheros; adjust for iwm0 (Intel) or other hardware
        # Create wpa_supplicant config
        cat > /etc/wpa_supplicant.conf <<EOF
network={
    ssid="$WIFI_SSID"
    psk="$WIFI_PASS"
}
EOF
        wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf
        dhclient wlan0
    fi

    # Power management tweaks for FreeBSD
    echo "pcie_aspm=off" >> /boot/loader.conf
    echo "hw.pci.do_power_nodriver=1" >> /boot/loader.conf  # Disable power for unloaded drivers

    echo "Setting Permissions for and then Starting Network Manager..."
    # FreeBSD doesn't have NetworkManager by default; use built-in rc scripts or install networkmgr
    pkg install -y networkmgr
    sysrc networkmgr_enable="YES"
    service networkmgr start
    cp /root/freebsd-installer-for-rs/dotfiles/system/rc.local /etc/rc.local  # FreeBSD uses /etc/rc.local for local startups
}

setup_input() {
    echo "*****************************************************"
    echo "INPUT HARDWARE                                       "
    echo "*****************************************************"

    echo "Disabling Touchscreen..."
    cp /root/freebsd-installer-for-rs/dotfiles/configs/99-disable-touchscreen.conf /usr/local/etc/X11/xorg.conf.d/99-disable-touchscreen.conf

    echo "Configuring Touchpad (disable tap-to-click and right-click areas)..."
    cp /root/freebsd-installer-for-rs/dotfiles/configs/70-synaptics.conf /usr/local/etc/X11/xorg.conf.d/70-synaptics.conf
}

setup_packaging() {
    echo "*****************************************************"
    echo "PACKAGING AND RELATED SECURITY"
    echo "*****************************************************"

    echo "Updating package repositories..."
    pkg update
    pkg upgrade -y

    echo "Setting mirror (to most reliable)..."
    # FreeBSD pkg config
    sed -i 's|url: "pkg+http://pkg.FreeBSD.org/\${ABI}/latest"|url: "pkg+http://pkg.FreeBSD.org/\${ABI}/quarterly"|' /etc/pkg/FreeBSD.conf

    echo "Fixing HTTPS/SSL so that git (among others) will work..."
    pkg install -y ca_root_nss
    update-ca-certificates --fresh
    ln -sf /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-bundle.crt
}

setup_ports() {  # Renamed from setup_sbopkg
    echo "*****************************************************"
    echo "PORTS PACKAGE BROWSER"
    echo "*****************************************************"

    echo "Installing portsnap for Ports tree..."
    pkg install -y portsnap
    portsnap fetch extract

    echo "Ports tree synced."
}

setup_locking() {
    echo "*****************************************************"
    echo "SCREEN LOCKING                                       "
    echo "*****************************************************"

    echo "Configuring Hardware to Lock on Laptop Reopen..."

    # FreeBSD uses devd for device events; adjust config
    cp ~/freebsd-installer-for-rs/dotfiles/lockscreen/lid-close /usr/local/etc/devd/lid-close.conf
    cp ~/freebsd-installer-for-rs/dotfiles/lockscreen/lock-screen.sh /usr/local/bin/lock-screen.sh
    cp ~/freebsd-installer-for-rs/dotfiles/lockscreen/lid-timer.sh /usr/local/bin/lid-timer.sh

    chmod +x /usr/local/bin/lock-screen.sh
    sysrc devd_enable="YES"
    service devd restart

    echo "Configuring xlock preferences..."
    cd ~
    cp /root/freebsd-installer-for-rs/dotfiles/x11/xdefaults ~/.Xdefaults
    xrdb merge ~/.Xdefaults
}

setup_audio() {
    echo "*****************************************************"
    echo "AUDIO/VOLUME					   "
    echo "*****************************************************"

    echo "Copying Volume Scripts..."
    cd ~
    sudo cp /root/freebsd-installer-for-rs/dotfiles/volume/* /usr/local/bin/
    sudo chmod 755 /usr/local/bin/volume_*.sh
}

setup_brightness() {
    echo "*****************************************************"
    echo "BRIGHTNESS (MONITOR AND KEYBOARD)                    "
    echo "*****************************************************"

    cd ~
    sudo cp /root/freebsd-installer-for-rs/dotfiles/brightness/* /usr/local/bin/
    sudo chmod 755 /usr/local/bin/brightness_*.sh

    sudo cp /root/freebsd-installer-for-rs/dotfiles/brightness/kbd_backlight/* /usr/local/bin/
    sudo chmod 755 /usr/local/bin/kbd_backlight_*.sh

    echo "Setting up keyboard backlight permissions..."
    # FreeBSD devd rules for backlight
    sudo cp /root/freebsd-installer-for-rs/dotfiles/udev/90-keyboard-backlight.rules /usr/local/etc/devd/90-keyboard-backlight.conf
    sudo service devd restart
}

setup_clipboard() {
    echo "*****************************************************"
    echo "CLIPBOARD                                            "
    echo "*****************************************************"

    echo "Installing xclip..."
    pkg install -y xclip
}

setup_vnc() {
    echo "*****************************************************"
    echo "VNC (VIRTUAL NETWORK COMPUTING)"
    echo "*****************************************************"

    echo "Installing FLTK (required library for vncviewer GUI)..."
    pkg install -y fltk

    echo "Installing TigerVNC (client and server)..."
    pkg install -y tigervnc

    # Copy and install VNC picker script as global command
    echo "Installing VNC picker script..."
    cp /root/freebsd-installer-for-rs/dotfiles/scripts/vnc-picker.sh /usr/local/bin/vnc-picker.sh
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

    echo "Setting up vim config for root..."
    mkdir -p /root/.vim/swap
    mkdir -p /root/.vim/backup
    mkdir -p /root/.vim/undo
    cp /root/freebsd-installer-for-rs/dotfiles/editors/vimrc /root/.vimrc
    echo "Vim config set up for root."
}

setup_git_lfs() {
    echo "*****************************************************"
    echo "GIT LARGE FILE STORAGE (GIT LFS)"
    echo "*****************************************************"

    echo "Installing Git LFS..."
    pkg install -y git-lfs

    echo "Setting up Git LFS globally..."
    git lfs install

    echo "Git LFS setup complete."
}

setup_neofetch() {
    echo "*****************************************************"
    echo "NEOFETCH                                             "
    echo "*****************************************************"

    echo "Configuring Neofetch..."
    pkg install -y neofetch
    cp /root/freebsd-installer-for-rs/dotfiles/neofetch/* /root/.config/neofetch
}

setup_fonts() {
    echo "*****************************************************"
    echo "ADDITIONAL FONTS                                     "
    echo "*****************************************************"

    echo "Installing Additional Fonts..."
    mkdir -p /usr/local/share/fonts/TTF
    cp ~/freebsd-installer-for-rs/fonts/BerkeleyMono-*.ttf /usr/local/share/fonts/TTF/
    fc-cache -fv
}

setup_yad() {
    echo "*****************************************************"
    echo "YAD (DIALOG TOOL)"
    echo "*****************************************************"

    echo "Installing yad in batch mode..."
    pkg install -y yad
}

setup_keychain() {
    echo "*****************************************************"
    echo "KEYCHAIN (SSH AGENT MANAGER)"
    echo "*****************************************************"

    echo "Installing keychain..."
    pkg install -y keychain
}

setup_lxappearance() {
    echo "*****************************************************"
    echo "LXAPPEARANCE (GTK THEME MANAGER)"
    echo "*****************************************************"

    echo "Installing lxappearance in batch mode..."
    pkg install -y lxappearance
}

setup_gtk_prefs() {
    echo "*****************************************************"
    echo "GTK PREFERENCES"
    echo "*****************************************************"

    echo "Applying GTK preferences after fonts..."
    if ! command -v lxappearance >/dev/null 2>&1; then
        echo "Error: lxappearance not found, skipping GTK prefs"
        return 1
    fi
    # Copy to /etc/skel for new users (FreeBSD skel location)
    mkdir -p /usr/share/skel/.config/gtk-3.0
    if [ -f /root/freebsd-installer-for-rs/dotfiles/gtk/.gtkrc-2.0 ]; then
        cp /root/freebsd-installer-for-rs/dotfiles/gtk/.gtkrc-2.0 /usr/share/skel/.gtkrc-2.0
    else
        echo "Warning: .gtkrc-2.0 not found, skipping GTK2 prefs"
    fi
    if [ -f /root/freebsd-installer-for-rs/dotfiles/gtk/settings.ini ]; then
        cp /root/freebsd-installer-for-rs/dotfiles/gtk/settings.ini /usr/share/skel/.config/gtk-3.0/settings.ini
    else
        echo "Warning: settings.ini not found, skipping GTK3 prefs"
    fi
    # Apply immediately to root
    mkdir -p ~/.config/gtk-3.0
    cp /usr/share/skel/.gtkrc-2.0 ~/.gtkrc-2.0 2>/dev/null || true
    cp /usr/share/skel/.config/gtk-3.0/settings.ini ~/.config/gtk-3.0/settings.ini 2>/dev/null || true
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
    pkg install -y chromium

    echo "Installing Widevine CDM for DRM support..."
    # FreeBSD-specific download and extraction
    cd /tmp
    fetch https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    ar x google-chrome-stable_current_amd64.deb
    tar -xf data.tar.xz
    mkdir -p /usr/local/lib/chromium/WidevineCdm/_platform_specific/linux_x64/
    cp opt/google/chrome/WidevineCdm/_platform_specific/linux_x64/libwidevinecdm.so /usr/local/lib/chromium/WidevineCdm/_platform_specific/linux_x64/
    cp opt/google/chrome/WidevineCdm/manifest.json /usr/local/lib/chromium/WidevineCdm/
    chmod 755 /usr/local/lib/chromium/WidevineCdm/_platform_specific/linux_x64/libwidevinecdm.so
    rm -rf google-chrome-stable_current_amd64.deb data.tar.xz control.tar.xz debian-binary opt
    echo "Widevine CDM installed."

    echo "Installing xdg-desktop-portal-gtk..."
    pkg install -y xdg-desktop-portal-gtk

    echo "Installing yad..."
    pkg install -y yad

    echo "Copying Chromium wrapper script..."
    mkdir -p /usr/local/bin
    cp /root/freebsd-installer-for-rs/dotfiles/chromium/chromium-wrapper.sh /usr/local/bin/chromium-wrapper.sh
    chmod +x /usr/local/bin/chromium-wrapper.sh
}

setup_openvpn() {
    echo "*****************************************************"
    echo "OPENVPN SETUP                                       "
    echo "*****************************************************"

    # Check if OpenVPN is installed
    if ! command -v openvpn >/dev/null 2>&1; then
        echo "Installing OpenVPN..."
        pkg install -y openvpn
    else
        echo "OpenVPN is already installed."
    fi

    # Read credentials from setup.keys
    if [ -z "$NORD_USER" ] || [ -z "$NORD_PASS" ]; then
        echo "NORD_USER or NORD_PASS not found in setup.keys. Skipping OpenVPN setup."
        return 1
    fi

    echo "Downloading NordVPN OpenVPN configs..."
    mkdir -p /usr/local/etc/openvpn/nordvpn
    cd /usr/local/etc/openvpn/nordvpn
    fetch https://downloads.nordcdn.com/configs/archives/servers/ovpn.zip || {
        echo "Failed to download ovpn configs. Skipping."
        return 1
    }
    unzip ovpn.zip
    rm ovpn.zip

    # Create auth file
    echo "$NORD_USER" > auth.txt
    echo "$NORD_PASS" >> auth.txt
    chmod 600 auth.txt

    # Modify ovpn files to use auth-user-pass
    for ovpn in *.ovpn; do
        if ! grep -q "auth-user-pass" "$ovpn"; then
            echo "auth-user-pass /usr/local/etc/openvpn/nordvpn/auth.txt" >> "$ovpn"
        fi
    done

    # Enable OpenVPN service (FreeBSD rc system)
    sysrc openvpn_enable="YES"

    # Copy VPN files to /usr/local/bin
    cp /root/freebsd-installer-for-rs/dotfiles/vpn/* /usr/local/bin/
    chmod +x /usr/local/bin/*.sh

    echo "OpenVPN setup complete."
}

setup_opencode() {
    echo "*****************************************************"
    echo "OPENCODE"
    echo "*****************************************************"

    echo "Installing OpenCode..."
    curl -fsSL https://opencode.ai/install | bash

    echo "Setting up OpenCode API key..."
    mkdir -p ~/.local/state ~/.local/share/opencode
    echo "{\"xai\": {\"type\": \"api\", \"key\": \"$XAI_API_KEY_CODE\"}}" > ~/.local/share/opencode/auth.json
}

setup_llm() {
    echo "*****************************************************"
    echo "LLM (LANGUAGE MODEL CLI)"
    echo "*****************************************************"

    # Create venv for llm
    mkdir -p /usr/local/venvs
    python3 -m venv /usr/local/venvs/llm
    . /usr/local/venvs/llm/bin/activate

    echo "Installing llm via pip in venv..."
    pip install llm

    echo "Installing prompt-toolkit for enhanced prompts..."
    pip install prompt-toolkit

    echo "Installing jq for log parsing..."
    pkg install -y jq

    echo "Copying modified cli.py..."
    cp /root/freebsd-installer-for-rs/dotfiles/llm/cli.py /usr/local/venvs/llm/lib/python3.9/site-packages/llm/cli.py

    echo "Installing llm-grok plugin..."
    llm install llm-grok

    echo "Setting up Grok API key..."
    mkdir -p /root/.config/io.datasette.llm
    echo '{"grok": "'$XAI_API_KEY_CHAT'"}' > /root/.config/io.datasette.llm/keys.json
    chmod 600 /root/.config/io.datasette.llm/keys.json

    echo "Setting default model to grok-4-1-fast..."
    llm models default grok-4-1-fast

    echo "Copying modified llm_grok plugin..."
    cp /root/freebsd-installer-for-rs/dotfiles/llm/llm_grok.py /usr/local/venvs/llm/lib/python3.9/site-packages/llm_grok.py

    echo "Copying llm wrapper script..."
    cp /root/freebsd-installer-for-rs/dotfiles/llm/llm-wrapper.sh /usr/local/bin/llm-wrapper.sh
    chmod +x /usr/local/bin/llm-wrapper.sh

    echo "Copying llm chat handler script..."
    cp /root/freebsd-installer-for-rs/dotfiles/llm/llm-chat-handler.py /usr/local/bin/llm-chat-handler.py
    chmod +x /usr/local/bin/llm-chat-handler.py

    echo "Copying llm select chat script..."
    cp /root/freebsd-installer-for-rs/dotfiles/llm/llm-select-chat.sh /usr/local/bin/llm-select-chat.sh
    chmod +x /usr/local/bin/llm-select-chat.sh

    echo "Copying llm system prompt..."
    cp /root/freebsd-installer-for-rs/dotfiles/llm/llm-system-prompt ~/.llm-system-prompt

    # Deactivate venv (sh compatible)
    PATH=$(echo "$PATH" | sed 's|/usr/local/venvs/llm/bin:||')
    echo "LLM setup complete in venv."
}

setup_xinitrc() {
    echo "*****************************************************"
    echo "XINITRC                                              "
    echo "*****************************************************"

    cd ~
    cp /root/freebsd-installer-for-rs/dotfiles/x11/xinitrc /root/.xinitrc
    chmod +x /root/.xinitrc

    cp /root/freebsd-installer-for-rs/dotfiles/shell/bashrc ~/.bashrc
}

setup_help() {
    echo "*****************************************************"
    echo "HELP SCRIPT"
    echo "*****************************************************"

    echo "Copying help script..."
    cp /root/freebsd-installer-for-rs/dotfiles/scripts/help.sh /usr/local/bin/
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
        cp -f /root/freebsd-installer-for-rs/dotfiles/suckless/${tool}/config.h config.h
        # For dwm, also copy the modified dwm.c
        if [ "${tool}" = "dwm" ]; then
            cp -f /root/freebsd-installer-for-rs/dotfiles/suckless/dwm/dwm.c dwm.c
        fi
        # For st, copy the patched source files
        if [ "${tool}" = "st" ]; then
            cp /root/freebsd-installer-for-rs/dotfiles/suckless/st/st.c st.c
            cp /root/freebsd-installer-for-rs/dotfiles/suckless/st/st.h st.h
            cp /root/suckless/st/config.def.h config.def.h
        fi
        # Build and install (requires root for 'install' step)
        sudo make clean install
        cd ..
    done
}

# Category definitions (use space-separated strings instead of arrays)
system_infra="Networking and WiFi Input Hardware Packaging and Security Ports Setup"
hardware_config="Screen Locking Audio/Volume Brightness Clipboard (xclip)"
security_access="Keychain OpenVPN"
dev_tools="VNC Vim Editor Git LFS OpenCode LLM"
ui_appearance="Neofetch Additional Fonts Yad (dialog tool) Lxappearance (GTK theme manager) GTK Preferences Xinitrc Suckless (dwm/dmenu/st)"
applications="Chromium"
utilities="Help Script"

categories="System Infrastructure Hardware Configuration Security & Access Development Tools User Interface & Appearance Applications Utilities"

# Flatten all options for non-interactive and case statement (space-separated)
options="$system_infra $hardware_config $security_access $dev_tools $ui_appearance $applications $utilities"

# Interactive menu
if $INTERACTIVE; then
    echo "Select categories and items to run. You can select from multiple categories."
    selected=""

    while true; do
        echo "Available categories:"
        i=1
        for cat in $categories; do
            echo "$i. $cat"
            i=$((i + 1))
        done
        num_cats=$(echo "$categories" | wc -w)
        echo "$((num_cats + 1)). All sections"
        echo "$((num_cats + 2)). Exit"

        printf "Enter category number, 'all' for everything, or 'done' to proceed: "
        read cat_choice
        case $cat_choice in
            all|All|ALL|$((num_cats + 1)))
                selected="$options"
                break
                ;;
            exit|Exit|EXIT|$((num_cats + 2)))
                exit 0
                ;;
            done|Done|DONE)
                break
                ;;
            [1-9]|10)
                cat_index=$((cat_choice - 1))
                if [ $cat_index -ge 0 ] && [ $cat_index -lt $num_cats ]; then
                    category=$(echo "$categories" | awk "{print \$$((cat_index + 1))}")
                    # Get submenu string
                    case $category in
                        "System Infrastructure") submenu="$system_infra" ;;
                        "Hardware Configuration") submenu="$hardware_config" ;;
                        "Security & Access") submenu="$security_access" ;;
                        "Development Tools") submenu="$dev_tools" ;;
                        "User Interface & Appearance") submenu="$ui_appearance" ;;
                        "Applications") submenu="$applications" ;;
                        "Utilities") submenu="$utilities" ;;
                    esac

                    echo "Select items in $category (numbers separated by commas, 'all' for category, 'back' to return):"
                    echo "Available items:"
                    i=1
                    for item in $submenu; do
                        echo "$i. $item"
                        i=$((i + 1))
                    done
                    num_items=$(echo "$submenu" | wc -w)
                    echo "$((num_items + 1)). All in $category"
                    echo "$((num_items + 2)). Back"

                    printf "Enter your choice: "
                    read item_choice
                    case $item_choice in
                        all|All|ALL|$((num_items + 1)))
                            selected="$selected $submenu"
                            ;;
                        back|Back|BACK|$((num_items + 2)))
                            ;;
                        *)
                            # Manual comma splitting (POSIX)
                            IFS=','
                            set -- $item_choice
                            unset IFS
                            for num in "$@"; do
                                if [ $num -ge 1 ] && [ $num -le $num_items ]; then
                                    item=$(echo "$submenu" | awk "{print \$$num}")
                                    selected="$selected $item"
                                fi
                            done
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

        if [ -n "$selected" ]; then
            echo "Selected so far: $selected"
        fi
    done

    if [ -z "$selected" ]; then
        echo "No sections selected. Exiting."
        exit 0
    fi

    echo "Selected sections: $selected"
    printf "Proceed with these sections? (y/N): "
    read confirm
    case $confirm in
        [yY]*) ;;
        *) exit 0 ;;
    esac
else
    selected="$options"
fi

# Execute selected functions (loop over space-separated string)
for section in $selected; do
    case $section in
        "Networking and WiFi") setup_networking ;;
        "Input Hardware") setup_input ;;
        "Packaging and Security") setup_packaging ;;
        "Ports Setup") setup_ports ;;
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
        "OpenVPN") setup_openvpn ;;
        "Lxappearance (GTK theme manager)") setup_lxappearance ;;
        "GTK Preferences") setup_gtk_prefs ;;
        "Chromium") setup_chromium ;;

        "OpenCode") setup_opencode ;;
        "LLM") setup_llm ;;
        "Xinitrc") setup_xinitrc ;;
        "Help Script") setup_help ;;
        "Suckless (dwm/st)") setup_suckless ;;
    esac
done

echo "Global setup complete. Run post-install-user.sh for per-user configs."
rsync -av --exclude=setup.keys /root/freebsd-installer-for-rs/ /usr/local/share/freebsd-installer-for-rs/