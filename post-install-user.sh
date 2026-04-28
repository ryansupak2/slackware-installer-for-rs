#!/bin/bash

# post-install-user.sh - Per-user setup for Slackware installer
# Run for each user after post-install-global.sh.

if [ "$1" = "--help" ]; then
    echo "Usage: $0 --user <username> [--create] [--wheel]"
    echo "Sets up per-user configs for the specified user."
    echo "Run as root. Copies dotfiles to user's home; prompts before overwriting."
    echo ""
    echo "Options:"
    echo "  --user <username>    Specify the target user (must exist unless --create used)."
    echo "  --create             Create the user if they don't exist (includes password setup)."
    echo "  --wheel              Add user to wheel group for sudo access (with --create)."
    echo ""
    echo "Examples:"
    echo "  $0 --user alice                      # Setup for existing user alice"
    echo "  $0 --user bob --create               # Create user bob and setup"
    echo "  $0 --user charlie --create --wheel   # Create user charlie with sudo and setup"
    echo ""
    echo "Prerequisites: Root must copy setup.keys to ~user/.local/share/opencode/ first."
    exit 0
fi

if [ "$EUID" -ne 0 ]; then echo "Run as root."; exit 1; fi
TARGET_USER=""
CREATE_USER=false
ADD_WHEEL=false
while [ $# -gt 0 ]; do
    case $1 in
        --user) TARGET_USER="$2"; shift 2 ;;
        --create) CREATE_USER=true; shift ;;
        --wheel) ADD_WHEEL=true; shift ;;
        *) echo "Invalid option. Use --help for usage."; exit 1 ;;
    esac
done
if [ -z "$TARGET_USER" ]; then echo "Specify --user. Use --help for usage."; exit 1; fi

if $CREATE_USER; then
    if id "$TARGET_USER" >/dev/null 2>&1; then echo "User $TARGET_USER exists; skipping creation."; else useradd -m "$TARGET_USER"; if $ADD_WHEEL; then usermod -aG wheel "$TARGET_USER"; fi; passwd "$TARGET_USER"; fi
else
    if ! id "$TARGET_USER" >/dev/null 2>&1; then echo "User $TARGET_USER does not exist."; exit 1; fi
fi
HOME_TARGET=$(eval echo ~$TARGET_USER)

echo "*****************************************************"
echo "USER-SPECIFIC SETUP FOR $TARGET_USER"
echo "*****************************************************"

echo "Copying User Preferences..."
target="$HOME_TARGET/.bashrc"
if [ -f "$target" ]; then
    if [ -t 0 ]; then
        read -p "Overwrite $target? (y/n): " choice
        case "$choice" in
            y|Y) cp ./dotfiles/bashrc "$target"; echo "Overwritten $target" ;;
            *) echo "Skipped $target (safety: no overwrite)" ;;
        esac
    else
        echo "Non-interactive mode: Skipped $target (safety: no overwrite)"
    fi
else
    cp ./dotfiles/bashrc "$target"
    echo "Copied to $target"
fi

echo "Updating vim Config..."

mkdir -p "$HOME_TARGET/.vim/swap"
mkdir -p "$HOME_TARGET/.vim/backup"
mkdir -p "$HOME_TARGET/.vim/undo"

target="$HOME_TARGET/.vimrc"
if [ -f "$target" ]; then
    if [ -t 0 ]; then
        read -p "Overwrite $target? (y/n): " choice
        case "$choice" in
            y|Y) cp ./dotfiles/vimrc "$target"; echo "Overwritten $target" ;;
            *) echo "Skipped $target (safety: no overwrite)" ;;
        esac
    else
        echo "Non-interactive mode: Skipped $target (safety: no overwrite)"
    fi
else
    cp ./dotfiles/vimrc "$target"
    echo "Copied to $target"
fi

echo "Configuring OpenCode..."
mkdir -p "$HOME_TARGET/.config/opencode"
target="$HOME_TARGET/.config/opencode/opencode.json"
if [ -f "$target" ]; then
    if [ -t 0 ]; then
        read -p "Overwrite $target? (y/n): " choice
        case "$choice" in
            y|Y) cp ./dotfiles/opencode/opencode.json "$target"; chmod 600 "$target"; echo "Overwritten $target" ;;
            *) echo "Skipped $target (safety: no overwrite)" ;;
        esac
    else
        echo "Non-interactive mode: Skipped $target (safety: no overwrite)"
    fi
else
    cp ./dotfiles/opencode/opencode.json "$target"
    chmod 600 "$target"
    echo "Copied to $target"
fi

mkdir -p "$HOME_TARGET/.local/share/opencode"
# NOTE: setup.keys must be pre-copied to ~/.local/share/opencode/ by root for each user (excluded from shared repo for security)
if [ -f "$HOME_TARGET/.local/share/opencode/setup.keys" ]; then
    chmod 600 "$HOME_TARGET/.local/share/opencode/setup.keys"
fi

echo "Configuring startx..."
target="$HOME_TARGET/.xinitrc"
if [ -f "$target" ]; then
    if [ -t 0 ]; then
        read -p "Overwrite $target? (y/n): " choice
        case "$choice" in
            y|Y) cp ./dotfiles/.xinitrc "$target"; echo "Overwritten $target" ;;
            *) echo "Skipped $target (safety: no overwrite)" ;;
        esac
    else
        echo "Non-interactive mode: Skipped $target (safety: no overwrite)"
    fi
else
    cp ./dotfiles/.xinitrc "$target"
    echo "Copied to $target"
fi

# Set ownership for user directories
chown -R "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.config/opencode" "$HOME_TARGET/.local/share/opencode"

echo "Per-user setup complete for $TARGET_USER."
