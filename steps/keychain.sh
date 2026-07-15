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
install_sbo "keychain"

# Determine which key to manage (prefer the configured root SSH key)
KEY_TYPE="${ROOT_SSH_KEY_TYPE:-ed25519}"
KEY_BASENAME="id_${KEY_TYPE}"
KEY_FILE="/root/.ssh/${KEY_BASENAME}"

if [ ! -f "$KEY_FILE" ]; then
    echo "No SSH key found at $KEY_FILE."
    echo "Generate one first (Root SSH Key step) or ensure a key exists before wiring keychain."
    echo "Keychain installed, but no eval line added yet."
    # Still count as success for the tool install itself
else
    # Append keychain eval line to root's .bashrc (idempotent)
    BASHRC="/root/.bashrc"

    if [ -f "$BASHRC" ]; then
        if ! grep -q "keychain --eval" "$BASHRC" 2>/dev/null; then
            {
                echo ""
                echo "# Root SSH keychain agent (added by post-install-global.sh)"
                echo "eval \`keychain --eval --quiet $KEY_FILE\`"
            } >> "$BASHRC"
            echo "Added keychain initialization line to $BASHRC"
        else
            echo "Keychain line already present in $BASHRC"
        fi
    else
        {
            echo "# Root SSH keychain agent (added by post-install-global.sh)"
            echo "eval \`keychain --eval --quiet $KEY_FILE\`"
        } > "$BASHRC"
        echo "Created $BASHRC with keychain line"
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
