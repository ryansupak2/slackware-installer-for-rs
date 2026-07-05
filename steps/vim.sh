#!/bin/bash
# steps/vim.sh - VI TEXT EDITOR

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "VI TEXT EDITOR                                       "
echo "*****************************************************"

ok=true

echo "Installing vim via sbopkg/slackpkg..."
if ! install_pkg "vim"; then
    echo "ERROR: failed to install vim."
    ok=false
fi

if $ok; then
    echo "Setting up vim config for root..."
    mkdir -p /root/.vim/swap
    mkdir -p /root/.vim/backup
    mkdir -p /root/.vim/undo
    if ! cp "$REPO_DIR/dotfiles/editors/vimrc" /root/.vimrc; then
        echo "ERROR: failed to copy vimrc."
        ok=false
    fi
fi

if $ok; then
    echo "SUCCESS: Vim installed and configured for root."
    exit 0
else
    echo "ERROR: Vim setup encountered errors."
    exit 1
fi
