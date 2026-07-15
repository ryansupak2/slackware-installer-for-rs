#!/bin/bash

# post-install-global.sh - Global system setup for Slackware Linux installer
# Run once as root after Slackware base install.
# Interactive menu by default; use --non-interactive for full run.
#
# Uses: slackpkg (official packages) + sbopkg (SlackBuilds.org)
# Init:  BSD-style /etc/rc.d/rc.* scripts (no systemd, no OpenRC)
# WiFi:  NetworkManager (nmcli) — Slackware default networking stack
# Boot:  elilo (kernel cmdline)
#
# Prerequisites:
#   - Slackware base install with series: A, AP, D, L, N, X
#   - Internet connection (NetworkManager or manual)
#   - Wayland users: select "wayland-base" under Core (dwl compositor)
#     (installs wlroots + mesa + seatd; no X server)
#   - Run with setup.keys.root populated (WIFI_*, NORD_*, XAI_*, ROOT_SSH_*, GITHUB_INSTALLER_*)
#
# TODO: intermittent VPN fix
# Argument parsing
INTERACTIVE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --non-interactive|--all)
            INTERACTIVE=false
            ;;
        --help)
            echo "Usage: $0 [--non-interactive|--all] [--help]"
            echo "Interactive menu by default; --non-interactive runs all sections."
            echo "Must be run as root. Run post-install-user.sh afterward for per-user configs."
            echo "Slackware edition: uses slackpkg + sbopkg + BSD init."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

# Set up dual logging: everything from this point on goes to the screen
LOG_DIR="/var/log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/${USER:-root}-post-install-global-$(date +%Y%m%d-%H%M%S).log"
export LOG_FILE
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=================================================="
echo "Installer log started: $(date)"
echo "Log file: $LOG_FILE (also duplicated to screen)"
echo "=================================================="
# Global setup (always run)
echo "*****************************************************"
echo "INITIALIZATION (Slackware Linux)"
echo "*****************************************************"

export REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Reading Keys from setup.keys.root..."
KEY_FILE="$REPO_DIR/setup.keys.root"
if [ -f "$KEY_FILE" ]; then
    while IFS='=' read -r key value; do
      [[ -z "$key" || "$key" =~ ^# ]] && continue
      export "$key"="$value"
    done < "$KEY_FILE"
else
    echo "Warning: $KEY_FILE not found. No keys loaded."
fi

# Set timezone to Chicago (America/Chicago)
if [ -f /usr/share/zoneinfo/America/Chicago ]; then
    ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime
    hwclock --hctosys 2>/dev/null || true
    echo "Timezone set to America/Chicago"
fi

# Global counters for FINAL SUMMARY (tracking Core, Networking, Hardware, and others)
success_count=0
error_count=0


firefox_ran=false

# Source shared helpers (install_pkg, log_msg, etc.)
if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

# (All individual setup steps have been moved to ./steps/*.sh)
# They are now standalone scripts that exit 0 on success / 1 on error.
# The main script only owns the menu, dispatch, and tally.
#
# Source the common helpers (already done above for the main script itself).
# Category definitions (for Slackware: removed glibc-compat, renamed apk step)
core_prereqs=("slackpkg-setup" "console-font" "ca-certificates" "wayland-base" "root-dotfiles")
networking=("wifi" "openvpn" "vnc" "remote-desktop")
hardware_config=("input-hardware" "screen-locking" "acpi-wakeup" "audio-volume" "brightness" "clipboard-wayland")
security_access=("root-ssh-key" "keychain" "github-ssh")
dev_tools=("suckless-foot" "vim" "git-lfs")
ui_appearance=("neofetch" "additional-fonts" "suckless-dwl")
applications=("firefox" "inkscape" "yad" "root-shortcuts" "slskd")
utilities=("help" "midnight-commander" "wifi-manager" "net-watch" "htop" "tmux")
audio_dsp=("sof-firmware" "sox" "whisper-cpp-vox")

categories=("Core" "Networking" "Hardware Configuration" "Security & Access" "Development Tools" "User Interface & Appearance" "Applications" "Utilities" "Audio/DSP")

# Flatten all options for non-interactive and case statement
options=("${core_prereqs[@]}" "${networking[@]}" "${hardware_config[@]}" "${security_access[@]}" "${dev_tools[@]}" "${ui_appearance[@]}" "${applications[@]}" "${utilities[@]}" "${audio_dsp[@]}")

# Interactive menu
if $INTERACTIVE; then
    echo "Select categories and items to run. You can select from multiple categories."
    selected=()

    while true; do
        echo "Available categories:"
        echo "A. All sections"
        for i in "${!categories[@]}"; do
            echo "$((i+1)). ${categories[$i]}"
        done
        echo "X. Exit"

        read -p "Enter category number, A for all, X to exit, or 'done' to proceed: " cat_choice
        case $cat_choice in
            a|A|all|All|ALL)
                selected=("${options[@]}")
                break
                ;;
            x|X|exit|Exit|EXIT)
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
                        "Core") submenu=("${core_prereqs[@]}") ;;
                        "Networking") submenu=("${networking[@]}") ;;
                        "Hardware Configuration") submenu=("${hardware_config[@]}") ;;
                        "Security & Access") submenu=("${security_access[@]}") ;;
                        "Development Tools") submenu=("${dev_tools[@]}") ;;
                        "User Interface & Appearance") submenu=("${ui_appearance[@]}") ;;
                        "Applications") submenu=("${applications[@]}") ;;
                        "Utilities") submenu=("${utilities[@]}") ;;
                        "Audio/DSP") submenu=("${audio_dsp[@]}") ;;
                    esac
                    echo "Select items in $category (numbers separated by commas, A for all in category, X to go back):"
                    echo "Available items:"
                    echo "A. All in $category"
                    for i in "${!submenu[@]}"; do
                        echo "$((i+1)). ${submenu[$i]}"
                    done
                    echo "X. Back"

                    read -p "Enter item number, A for all in category, X to go back: " item_choice
                    case $item_choice in
                        a|A|all|All|ALL)
                            for item in "${submenu[@]}"; do
                                selected+=("$item")
                            done
                            ;;
                        x|X|back|Back|BACK)
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

# Execute selected steps (each step script exits 0 for success, 1 for error)
for section in "${selected[@]}"; do
    case $section in
        "slackpkg-setup")
            if ./steps/slackpkg-setup.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "console-font")
            if ./steps/console-font.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "ca-certificates")
            if ./steps/ca-certificates.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "wayland-base")
            if ./steps/wayland-base.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "root-dotfiles")
            if ./steps/root-dotfiles.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "wifi")
            if ./steps/wifi.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "openvpn")
            if ./steps/openvpn.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "vnc")
            if ./steps/vnc.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "remote-desktop")
            if ./steps/remote-desktop.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "input-hardware")
            if ./steps/input-hardware.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "screen-locking")
            if ./steps/screen-locking.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "audio-volume")
            if ./steps/audio-volume.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "brightness")
            if ./steps/brightness.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "clipboard-wayland")
            if ./steps/clipboard-wayland.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "acpi-wakeup")
            if ./steps/acpi-wakeup.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "vim")
            if ./steps/vim.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "git-lfs")
            if ./steps/git-lfs.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "neofetch")
            if ./steps/neofetch.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "additional-fonts")
            if ./steps/additional-fonts.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "root-ssh-key")
            if ./steps/root-ssh-key.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "keychain")
            if ./steps/keychain.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "github-ssh")
            if ./steps/github-ssh.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "firefox")
            firefox_ran=true
            if ./steps/firefox.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "inkscape")
            if ./steps/inkscape.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "yad")
            if ./steps/yad.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "root-shortcuts")
            if ./steps/user-surf-shortcuts.sh root; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "slskd")
            if ./steps/slskd.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "sof-firmware")
            if ./steps/sof-firmware.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "sox")
            if ./steps/sox.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "whisper-cpp-vox")
            if ./steps/whisper-cpp-vox.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "midnight-commander")
            if ./steps/midnight-commander.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "wifi-manager")
            if ./steps/wifi-manager.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "net-watch")
            if ./steps/net-watch.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "htop")
            if ./steps/htop.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "tmux")
            if ./steps/tmux.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "help")
            if ./steps/help.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "suckless-dwl")
            if ./steps/suckless-dwl.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
        "suckless-foot")
            if ./steps/suckless-foot.sh; then
                success_count=$((success_count + 1))
            else
                error_count=$((error_count + 1))
            fi
            ;;
    esac
done

# FireFox DRM notes (shown before final summary)
if [ "$firefox_ran" = true ]; then
echo ""
echo "*****************************************************"
echo "NEXT STEPS FOR FIREFOX + DRM"
echo "*****************************************************"
echo ""
echo "The installer has:"
echo "  - Installed firefox + Widevine CDM"
echo "  - Pre-provisioned Widevine CDM at /usr/lib64/firefox/gmp-widevinecdm/"
echo "  - Installed dark GTK theme + userChrome.css"
echo "  - Injected Widevine prefs into existing Firefox profiles"
echo ""
echo "STEP 1: Launch Firefox:"
echo "   firefox"
echo ""
echo "STEP 2: Verify prefs in about:config:"
echo "   media.gmp-widevinecdm.enabled   = true"
echo "   media.gmp-widevinecdm.visible   = true"
echo "   media.eme.enabled               = true"
echo "   media.gmp-manager.updateEnabled = false"
echo ""
echo "STEP 3: Test DRM at https://www.netflix.com"
echo ""
echo "STEP 4: Check about:support for Widevine CDM"
echo ""
fi

# Log file location
echo ""
if [ -f "$LOG_FILE" ]; then
    echo "Full installer output has been captured to: $LOG_FILE"
    echo "(View with: less $LOG_FILE  or  tail -n 200 $LOG_FILE)"
fi

# FINAL SUMMARY — must be the very last thing printed
echo ""
echo "*****************************************************"
echo "FINAL SUMMARY"
echo "*****************************************************"
echo ""
echo "SUCCESS: $success_count"
echo "ERROR:   $error_count"

echo ""
