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
    src="$REPO_DIR/dotfiles/shell/bashrc"

    if [ -f "$target" ]; then
        if ! cmp -s "$src" "$target" 2>/dev/null; then
            backup="$HOME_TARGET/.bashrc.backup-$(date +%Y%m%d-%H%M%S)"
            cp "$target" "$backup"
            echo "  Existing .bashrc differs from template — backed up to $(basename "$backup")"
        else
            echo "  .bashrc unchanged from template — skipping"
            return
        fi
    fi
    cp "$src" "$target"
    echo "  Deployed $target"

    # .bash_profile for login shells
    bp_target="$HOME_TARGET/.bash_profile"
    bp_src="$REPO_DIR/dotfiles/shell/bash_profile"
    if [ -f "$bp_target" ]; then
        if ! cmp -s "$bp_src" "$bp_target" 2>/dev/null; then
            bp_backup="$HOME_TARGET/.bash_profile.backup-$(date +%Y%m%d-%H%M%S)"
            cp "$bp_target" "$bp_backup"
            echo "  Existing .bash_profile differs from template — backed up to $(basename "$bp_backup")"
            cp "$bp_src" "$bp_target"
            echo "  Deployed $bp_target"
        else
            echo "  .bash_profile unchanged from template — skipping"
        fi
    else
        cp "$bp_src" "$bp_target" 2>/dev/null || true
        echo "  Deployed $bp_target"
    fi
    chmod 600 "$bp_target" 2>/dev/null || true
}

setup_bashrc

chown "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.bashrc" "$HOME_TARGET/.bash_profile" 2>/dev/null || true

echo "SUCCESS: Bashrc configured for $TARGET_USER."
exit 0