#!/bin/bash
# steps/user-bashrc.sh - BASHRC + BASH_PROFILE FOR TARGET USER

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
TARGET_USER="${TARGET_USER:-$1}"

if [ -z "$TARGET_USER" ]; then
    echo "ERROR: TARGET_USER not set"
    exit 1
fi

echo "*****************************************************"
echo "BASHRC FOR $TARGET_USER"
echo "*****************************************************"

HOME_TARGET=$(eval echo ~$TARGET_USER)

setup_bashrc() {
    echo "Copying User Preferences (bashrc)..."
    target="$HOME_TARGET/.bashrc"
    cp "$REPO_DIR/dotfiles/shell/bashrc" "$target"
    echo "Deployed $target"

    # .bash_profile for login shells
    bp_target="$HOME_TARGET/.bash_profile"
    cp "$REPO_DIR/dotfiles/shell/bash_profile" "$bp_target" 2>/dev/null || true
    chmod 600 "$bp_target" 2>/dev/null || true
}

setup_bashrc

chown "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.bashrc" "$HOME_TARGET/.bash_profile" 2>/dev/null || true

echo "SUCCESS: Bashrc configured for $TARGET_USER."
exit 0