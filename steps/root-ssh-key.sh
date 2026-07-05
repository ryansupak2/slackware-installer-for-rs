#!/bin/bash
# steps/root-ssh-key.sh - ROOT SSH KEY

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "ROOT SSH KEY"
echo "*****************************************************"

ok=true

# Read configuration from keys (with sensible defaults)
KEY_TYPE="${ROOT_SSH_KEY_TYPE:-ed25519}"
KEY_COMMENT="${ROOT_SSH_COMMENT:-root@$(hostname 2>/dev/null || echo localhost)}"
PASSPHRASE="${ROOT_SSH_PASSPHRASE:-}"

KEY_BASENAME="id_${KEY_TYPE}"
KEY_FILE="/root/.ssh/${KEY_BASENAME}"
PUB_FILE="${KEY_FILE}.pub"

echo "Setting up root SSH key (type: $KEY_TYPE)..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [ ! -f "$KEY_FILE" ]; then
    if ! ssh-keygen -t "$KEY_TYPE" -f "$KEY_FILE" -N "$PASSPHRASE" -C "$KEY_COMMENT"; then
        echo "ERROR during key generation."
        ok=false
    fi
else
    echo "SSH key already exists at $KEY_FILE (skipping generation)"
fi

if [ -f "$PUB_FILE" ]; then
    echo "Root SSH public key:"
    cat "$PUB_FILE"
fi

if $ok; then
    echo "SUCCESS: Root SSH key configured."
    exit 0
else
    echo "ERROR: Root SSH key setup encountered errors."
    exit 1
fi
