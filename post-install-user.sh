#!/bin/bash

# post-install-user.sh - Per-user setup for Slackware installer
# Run for each user after post-install-global.sh.

if [ "$1" = "--help" ]; then
    echo "Usage: ./post-install-user.sh"
    echo "Performs per-user setup: copies dotfiles and configs to home directory."
    echo "Run as the target user (e.g., su - UserName -c ./post-install-user.sh)."
    echo "Requires post-install-global.sh to have run first."
    exit 0
fi

echo "*****************************************************"
echo "USER-SPECIFIC SETUP"
echo "*****************************************************"

echo "Copying User Preferences..."
cp /root/slackware-installer-for-rs/dotfiles/bashrc $HOME/.bashrc

echo "Updating vim Config..."

mkdir -p ~/.vim/swap
mkdir -p ~/.vim/backup
mkdir -p ~/.vim/undo

cp /root/slackware-installer-for-rs/dotfiles/vimrc $HOME/.vimrc

echo "Configuring OpenCode..."
mkdir -p ~/.config/opencode
cp /root/slackware-installer-for-rs/dotfiles/opencode/opencode.json ~/.config/opencode/opencode.json
chmod 600 ~/.config/opencode/opencode.json

mkdir -p ~/.local/share/opencode
#TODO: replace keys in file with keys from memory of same name
cp /root/slackware-installer-for-rs/setup.keys ~/.local/share/opencode/setup.keys
chmod 600 ~/.local/share/opencode/setup.keys

echo "Configuring startx..."
cp /root/slackware-installer-for-rs/dotfiles/.xinitrc ~/.xinitrc

echo "Per-user setup complete."
