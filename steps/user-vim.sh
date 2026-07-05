#!/bin/bash
# steps/user-vim.sh - VIM CONFIG FOR TARGET USER

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
TARGET_USER="${TARGET_USER:-$1}"

if [ -z "$TARGET_USER" ]; then
    echo "ERROR: TARGET_USER not set"
    exit 1
fi

echo "*****************************************************"
echo "VIM FOR $TARGET_USER"
echo "*****************************************************"

HOME_TARGET=$(eval echo ~$TARGET_USER)

setup_vim() {
    echo "Updating vim Config..."
    mkdir -p "$HOME_TARGET/.vim/swap"
    mkdir -p "$HOME_TARGET/.vim/backup"
    mkdir -p "$HOME_TARGET/.vim/undo"
    chown -R "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.vim"

    target="$HOME_TARGET/.vimrc"
    cp "$REPO_DIR/dotfiles/editors/vimrc" "$target"
    echo "Deployed $target"
}

setup_vim

chown "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.vimrc" 2>/dev/null || true

echo "SUCCESS: Vim configured for $TARGET_USER."
exit 0