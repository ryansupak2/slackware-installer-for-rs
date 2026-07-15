#!/bin/bash
# steps/user-github-ssh.sh - GITHUB SSH (PAT + gh) FOR TARGET USER

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
TARGET_USER="${TARGET_USER:-$1}"

if [ -z "$TARGET_USER" ]; then
    echo "ERROR: TARGET_USER not set"
    exit 1
fi
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "GITHUB SSH (PAT + gh) FOR $TARGET_USER"
echo "*****************************************************"

HOME_TARGET=$(eval echo ~$TARGET_USER)

# Try to load keys (same keys used by global)
KEY_FILE="$REPO_DIR/setup.keys.$TARGET_USER"
if [ -f "$KEY_FILE" ]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        export "$key"="$value"
    done < "$KEY_FILE"
elif [ -f "$REPO_DIR/setup.keys.root" ]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        export "$key"="$value"
    done < "$REPO_DIR/setup.keys.root"
fi

ok=true

if [ -z "$GITHUB_INSTALLER_PAT" ]; then
    echo "No GITHUB_INSTALLER_PAT found in setup.keys.* (skipping GitHub auth)."
    echo "SUCCESS: GitHub SSH step skipped (no PAT)."
    exit 0
fi

echo "Installing github-cli (if missing)..."
if ! command -v gh >/dev/null 2>&1; then
    install_sbo "github-cli" || {
        echo "Warning: could not install github-cli via sbopkg"
    }
fi

if command -v gh >/dev/null 2>&1; then
    echo "Authenticating $TARGET_USER with GitHub PAT..."
    if ! su - "$TARGET_USER" -c "printf '%s' \"$GITHUB_INSTALLER_PAT\" | gh auth login --with-token" >/dev/null 2>&1; then
        echo "gh auth login failed for $TARGET_USER (check PAT scopes: repo + admin:public_key + gist)."
        ok=false
    else
        echo "Authenticated gh for $TARGET_USER."
        echo "Configuring git credential helper for $TARGET_USER..."
        if su - "$TARGET_USER" -c "gh auth setup-git" >/dev/null 2>&1; then
            echo "Git credential helper configured (gh)."
        fi
    fi

    if $ok; then
        if [ -n "$GITHUB_INSTALLER_USERNAME" ]; then
            su - "$TARGET_USER" -c "git config --global user.name \"$GITHUB_INSTALLER_USERNAME\"" 2>/dev/null || true
        fi
        if [ -n "$GITHUB_INSTALLER_EMAIL" ]; then
            su - "$TARGET_USER" -c "git config --global user.email \"$GITHUB_INSTALLER_EMAIL\"" 2>/dev/null || true
        fi

        # Try to upload SSH key
        for keyfile in "$HOME_TARGET/.ssh/id_ed25519" "$HOME_TARGET/.ssh/id_rsa" "$HOME_TARGET/.ssh/id_ecdsa"; do
            if [ -f "${keyfile}.pub" ]; then
                TITLE="${TARGET_USER}@$(hostname 2>/dev/null || echo slackware)-$(date +%Y-%m-%d)"
                echo "Uploading ${keyfile}.pub to GitHub for $TARGET_USER..."
                if su - "$TARGET_USER" -c "gh ssh-key add \"${keyfile}.pub\" --title \"$TITLE\"" 2>/dev/null; then
                    echo "SSH public key uploaded to GitHub for $TARGET_USER."
                    break
                fi
            fi
        done

        # Load SSH key into agent
        echo "Loading SSH key into agent for $TARGET_USER..."
        for keyfile in "$HOME_TARGET/.ssh/id_ed25519" "$HOME_TARGET/.ssh/id_rsa" "$HOME_TARGET/.ssh/id_ecdsa"; do
            if [ -f "$keyfile" ]; then
                if command -v keychain >/dev/null 2>&1; then
                    su - "$TARGET_USER" -c "eval \$(keychain --eval --quiet '$keyfile')" 2>/dev/null || true
                else
                    su - "$TARGET_USER" -c "ssh-add '$keyfile'" 2>/dev/null || true
                fi
                break
            fi
        done

        echo "Seeding github.com host key for $TARGET_USER..."
        su - "$TARGET_USER" -c "ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null" 2>/dev/null || true

        echo "Testing GitHub SSH for $TARGET_USER..."
        if su - "$TARGET_USER" -c "timeout 8 ssh -T git@github.com 2>&1" | grep -qi "successfully authenticated"; then
            echo "GitHub SSH test passed for $TARGET_USER."
        else
            echo "GitHub SSH test did not confirm (may need time to propagate)."
        fi
    fi
else
    echo "github-cli (gh) not available; skipping PAT auth for $TARGET_USER."
fi

if $ok; then
    echo "SUCCESS: GitHub SSH / gh configured for $TARGET_USER."
    exit 0
else
    echo "ERROR: GitHub SSH setup had failures for $TARGET_USER."
    exit 1
fi
