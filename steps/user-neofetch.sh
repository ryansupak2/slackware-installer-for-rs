#!/bin/bash
# steps/user-neofetch.sh - NEOFETCH GPU LINE FOR TARGET USER

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
TARGET_USER="${TARGET_USER:-$1}"

if [ -z "$TARGET_USER" ]; then
    echo "ERROR: TARGET_USER not set"
    exit 1
fi

echo "*****************************************************"
echo "NEOFETCH FOR $TARGET_USER"
echo "*****************************************************"

HOME_TARGET=$(eval echo ~$TARGET_USER)

setup_neofetch() {
    echo "Setting up Neofetch..."

    if ! mkdir -p "$HOME_TARGET/.config/neofetch" 2>/dev/null; then
        echo "ERROR: could not create $HOME_TARGET/.config/neofetch directory."
        exit 1
    fi

    cfg="$HOME_TARGET/.config/neofetch/config.conf"
    art="$HOME_TARGET/.config/neofetch/bobdobbs.txt"
    cp "$REPO_DIR/dotfiles/neofetch/config.conf" "$cfg"
    cp "$REPO_DIR/dotfiles/neofetch/bobdobbs.txt" "$art"
    echo "  neofetch config deployed"

    chown -R "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.config/neofetch" 2>/dev/null || true
    echo "SUCCESS: Neofetch configured for $TARGET_USER."
    echo "  - Uses bobdobbs ASCII art as default splash."
    echo "  - GPU line included in system info."
    echo "  - Run 'neofetch' to see it."
    exit 0
}

setup_neofetch
