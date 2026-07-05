#!/bin/bash
# steps/user-ssh.sh - SSH KEY + CONFIG + AGENT FOR TARGET USER

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
TARGET_USER="${TARGET_USER:-$1}"

if [ -z "$TARGET_USER" ]; then
    echo "ERROR: TARGET_USER not set"
    exit 1
fi

echo "*****************************************************"
echo "SSH SETUP FOR $TARGET_USER"
echo "*****************************************************"

HOME_TARGET=$(eval echo ~$TARGET_USER)

setup_ssh() {
    echo "Setting up SSH for $TARGET_USER..."

    mkdir -p "$HOME_TARGET/.ssh"
    chmod 700 "$HOME_TARGET/.ssh"
    chown "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.ssh"

    # Determine key type (prefer ed25519, matching root default)
    KEY_TYPE="${ROOT_SSH_KEY_TYPE:-ed25519}"
    KEYFILE="$HOME_TARGET/.ssh/id_${KEY_TYPE}"

    # Also check for legacy RSA key if ed25519 doesn't exist yet
    if [ ! -f "$KEYFILE" ] && [ -f "$HOME_TARGET/.ssh/id_rsa" ]; then
        KEY_TYPE="rsa"
        KEYFILE="$HOME_TARGET/.ssh/id_rsa"
    fi

    if [ ! -f "$KEYFILE" ]; then
        echo "Generating SSH key (type: $KEY_TYPE)..."
        if [ "$KEY_TYPE" = "rsa" ]; then
            su - "$TARGET_USER" -c "ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N '' -C '$TARGET_USER@localhost'"
        else
            su - "$TARGET_USER" -c "ssh-keygen -t $KEY_TYPE -f ~/.ssh/id_${KEY_TYPE} -N '' -C '$TARGET_USER@localhost'"
        fi
        echo "SSH key generated. Public key: ${KEYFILE}.pub"
        echo "Add the public key to your GitHub or remote servers."
    else
        echo "SSH key already exists at $KEYFILE"
    fi

    if [ ! -f "$HOME_TARGET/.ssh/config" ]; then
        cp "$REPO_DIR/dotfiles/ssh/config" "$HOME_TARGET/.ssh/config"
        chmod 600 "$HOME_TARGET/.ssh/config"
        chown "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.ssh/config"
        echo "Basic SSH config created."
    fi

    if command -v keychain >/dev/null 2>&1; then
        echo "eval \\`keychain --eval --quiet ~/.ssh/id_${KEY_TYPE}\\`" >> "$HOME_TARGET/.bashrc"
        echo "SSH keychain setup added to $HOME_TARGET/.bashrc"
    else
        echo "eval \"\\$(ssh-agent -s)\" && ssh-add ~/.ssh/id_${KEY_TYPE}" >> "$HOME_TARGET/.bashrc"
        echo "SSH agent setup added to $HOME_TARGET/.bashrc (keychain not available)"
    fi

    chown -R "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.ssh"
}

setup_ssh

echo "SUCCESS: SSH configured for $TARGET_USER."
exit 0