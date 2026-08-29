#!/bin/bash
# steps/user-fastfetch.sh - FASTFETCH FOR TARGET USER (Slackware)
REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
TARGET_USER="${TARGET_USER:-$1}"
if [ -z "$TARGET_USER" ]; then echo "ERROR: TARGET_USER not set"; exit 1; fi
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"
if [ -f "$REPO_DIR/lib/common.sh" ]; then . "$REPO_DIR/lib/common.sh"; fi
echo "*****************************************************"
echo "FASTFETCH FOR $TARGET_USER"
echo "*****************************************************"
HOME_TARGET=$(eval echo ~$TARGET_USER)
ok=true

echo "Setting up Fastfetch..."
if ! mkdir -p "$HOME_TARGET/.config/fastfetch" 2>/dev/null; then
    echo "ERROR: could not create directory."
    ok=false
fi

if $ok; then
    cfg="$HOME_TARGET/.config/fastfetch/config.jsonc"
    art="$HOME_TARGET/.config/fastfetch/bobdobbs.txt"
    cp "$REPO_DIR/dotfiles/fastfetch/config.jsonc" "$cfg" || ok=false
    cp "$REPO_DIR/dotfiles/fastfetch/bobdobbs.txt" "$art" || ok=false
    echo "  fastfetch config deployed"
    chown -R "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.config/fastfetch" 2>/dev/null || true
fi

# Remove legacy neofetch config (migrated to fastfetch)
if [ -d "$HOME_TARGET/.config/neofetch" ]; then
    echo "Removing legacy neofetch config..."
    rm -rf "$HOME_TARGET/.config/neofetch" 2>/dev/null || true
fi

if $ok; then
    echo "SUCCESS: Fastfetch configured for $TARGET_USER."
    echo "  - Uses bobdobbs ASCII art as default splash."
    echo "  - Run 'fastfetch' to see it."
    exit 0
else
    echo "ERROR: Fastfetch config failed for $TARGET_USER."
    exit 1
fi
