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
    ok=true

    if ! mkdir -p "$HOME_TARGET/.config/neofetch" 2>/dev/null; then
        echo "ERROR: could not create $HOME_TARGET/.config/neofetch directory."
        ok=false
    fi

    if $ok; then
        cfg="$HOME_TARGET/.config/neofetch/config.conf"
        art="$HOME_TARGET/.config/neofetch/bobdobbs.txt"

        if [ -f "$cfg" ]; then
            read -p "Overwrite $cfg? (y/N): " choice
            case "$choice" in
                y|Y)
                    cp "$REPO_DIR/dotfiles/neofetch/config.conf" "$cfg"
                    cp "$REPO_DIR/dotfiles/neofetch/bobdobbs.txt" "$art"
                    echo "Overwritten $cfg + bobdobbs.txt art"
                    ;;
                *)
                    echo "Skipped $cfg (safety: no overwrite)"
                    ;;
            esac
        else
            cp "$REPO_DIR/dotfiles/neofetch/config.conf" "$cfg"
            cp "$REPO_DIR/dotfiles/neofetch/bobdobbs.txt" "$art"
            echo "Created config with bobdobbs art."
        fi
    fi

    if $ok; then
        chown -R "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.config/neofetch" 2>/dev/null || true
        echo "SUCCESS: Neofetch configured for $TARGET_USER."
        echo "  - Uses bobdobbs ASCII art as default splash."
        echo "  - GPU line included in system info."
        echo "  - Run 'neofetch' to see it."
        exit 0
    else
        echo "ERROR: Neofetch setup encountered errors for $TARGET_USER."
        exit 1
    fi
}

setup_neofetch
