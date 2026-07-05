#!/bin/bash
# steps/github-ssh.sh - GITHUB SSH (PAT + github-cli)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "GITHUB SSH (PAT + github-cli)"
echo "*****************************************************"

ok=true

if [ -z "$GITHUB_INSTALLER_PAT" ]; then
    echo "Missing GITHUB_INSTALLER_PAT in setup.keys.root."
    ok=false
else
    echo "Installing github-cli..."
    if ! install_sbo "github-cli"; then
        echo "Failed to install github-cli."
        ok=false
    fi

    if $ok; then
        echo "Authenticating with GitHub using PAT (requires admin:public_key + gist scope)..."
        if ! printf '%s' "$GITHUB_INSTALLER_PAT" | gh auth login --with-token >/dev/null 2>&1; then
            echo "gh auth login failed (check PAT scopes: repo + admin:public_key + gist)."
            ok=false
        else
            echo "Authenticated gh CLI with PAT."

            # Explicitly configure git to use gh as the credential helper
            echo "Configuring git credential helper (root)..."
            if gh auth setup-git >/dev/null 2>&1; then
                echo "Git credential helper configured (gh)."
            else
                echo "Warning: gh auth setup-git failed (non-fatal if only using SSH remotes)."
            fi
        fi
    fi

    if $ok; then
        # Configure git identity (best effort)
        if [ -n "$GITHUB_INSTALLER_USERNAME" ]; then
            git config --global user.name "$GITHUB_INSTALLER_USERNAME"
        fi
        if [ -n "$GITHUB_INSTALLER_EMAIL" ]; then
            git config --global user.email "$GITHUB_INSTALLER_EMAIL"
        fi

        # Best-effort: upload root SSH public key (non-fatal if it already exists)
        UPLOADED=false
        for keyfile in /root/.ssh/id_ed25519 /root/.ssh/id_rsa /root/.ssh/id_ecdsa; do
            if [ -f "${keyfile}.pub" ]; then
                TITLE="${ROOT_SSH_COMMENT:-root@$(hostname 2>/dev/null || echo slackware)-$(date +%Y-%m-%d)}"
                echo "Attempting to upload ${keyfile}.pub to GitHub..."
                if gh ssh-key add "${keyfile}.pub" --title "$TITLE" 2>/dev/null; then
                    echo "SSH public key uploaded to GitHub."
                    UPLOADED=true
                    break
                else
                    echo "Upload skipped or key already present on account."
                fi
            fi
        done
        if [ "$UPLOADED" = false ]; then
            echo "No SSH key was newly uploaded (harmless if it already exists on GitHub)."
        fi

        # Explicitly load root's SSH key into the agent right now
        echo "Loading SSH key into agent for root..."
        for keyfile in /root/.ssh/id_ed25519 /root/.ssh/id_rsa /root/.ssh/id_ecdsa; do
            if [ -f "$keyfile" ]; then
                if command -v keychain >/dev/null 2>&1; then
                    eval $(keychain --eval --quiet "$keyfile" 2>/dev/null) || true
                else
                    ssh-add "$keyfile" 2>/dev/null || true
                fi
                echo "SSH key $keyfile loaded into agent."
                break
            fi
        done

        # Pre-seed github.com host key to avoid interactive prompt on first SSH
        echo "Seeding github.com host key for root..."
        ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null || true

        # Informational SSH test (never fatal for this step)
        echo "Testing GitHub SSH connectivity (ssh -T git@github.com)..."
        if timeout 8 ssh -T git@github.com 2>&1 | grep -qi "successfully authenticated"; then
            echo "GitHub SSH authentication test passed."
        else
            echo "GitHub SSH test did not confirm (key may need a minute to propagate, or use manual test: ssh -T git@github.com)."
        fi

        # Verify credential helper is actually configured
        CRED_HELPER=$(git config --global --get-urlmatch credential.helper https://github.com 2>/dev/null)
        if [ -n "$CRED_HELPER" ]; then
            echo "Git credential helper confirmed for github.com: $CRED_HELPER"
        else
            echo "WARNING: No git credential helper detected. HTTPS git operations may prompt for password."
            echo "         Run 'gh auth setup-git' to fix."
        fi
    fi
fi

if $ok; then
    echo "SUCCESS: GitHub SSH (gh auth + optional key upload) configured."
    exit 0
else
    echo "ERROR: GitHub SSH setup failed."
    exit 1
fi
