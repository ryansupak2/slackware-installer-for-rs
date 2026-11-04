#!/bin/bash
# steps/keychain.sh - KEYCHAIN (SSH AGENT MANAGER)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "KEYCHAIN (SSH AGENT MANAGER)"
echo "*****************************************************"

ok=true

echo "Installing keychain..."
# sbopkg used to exit 0 on a failed build, silently leaving keychain absent.
if ! install_sbo "keychain"; then
    echo "ERROR: keychain install failed."
    exit 1
fi

# Determine which key to manage (prefer the configured root SSH key)
KEY_TYPE="${ROOT_SSH_KEY_TYPE:-ed25519}"
KEY_BASENAME="id_${KEY_TYPE}"
KEY_FILE="/root/.ssh/${KEY_BASENAME}"

if [ ! -f "$KEY_FILE" ]; then
    echo "No SSH key found at $KEY_FILE."
    echo "Generate one first (Root SSH Key step) or ensure a key exists before wiring keychain."
    echo "Keychain installed, but the agent will not start until the key exists."
    # Still count as success for the tool install itself
else
    # The keychain eval line is part of the canonical dotfiles/shell/bashrc
    # (deployed by steps/root-dotfiles.sh) — never appended here, so that
    # re-deploying bashrc cannot lose it and repeated runs cannot duplicate it.
    BASHRC="/root/.bashrc"
    if [ -f "$BASHRC" ] && grep -q "keychain --eval" "$BASHRC" 2>/dev/null; then
        echo "Keychain eval line present in $BASHRC (from dotfiles/shell/bashrc)."
    else
        echo "WARNING: no keychain eval line in $BASHRC."
        echo "         Re-deploy shell dotfiles: REPO_DIR=$REPO_DIR bash steps/root-dotfiles.sh"
    fi

    # Initialize keychain for the current (root) session right now (so it is active immediately)
    if command -v keychain >/dev/null 2>&1; then
        eval $(keychain --eval --quiet "$KEY_FILE" 2>/dev/null) || true
        echo "Keychain agent initialized for current root session."
    fi
fi

if $ok; then
    echo "SUCCESS: keychain configured."
    exit 0
else
    echo "ERROR: keychain setup encountered errors."
    exit 1
fi
