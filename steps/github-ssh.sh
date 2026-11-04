#!/bin/bash
# steps/github-ssh.sh - GITHUB SSH (PAT + github-cli)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

# Standalone runs: the parent installer exports these keys, but this step is
# also executed directly (and by tests), so load setup.keys.root when needed.
if [ -z "${GITHUB_INSTALLER_PAT:-}" ] && declare -F read_setup_keys >/dev/null 2>&1 \
   && [ -f "$REPO_DIR/setup.keys.root" ]; then
    read_setup_keys
fi

echo "*****************************************************"
echo "GITHUB SSH (PAT + github-cli)"
echo "*****************************************************"

ok=true
GH_AUTH=false

if [ -z "${GITHUB_INSTALLER_PAT:-}" ]; then
    echo "Missing GITHUB_INSTALLER_PAT in setup.keys.root."
    ok=false
else
    echo "Installing github-cli..."
    if ! install_sbo "github-cli"; then
        echo "Failed to install github-cli."
        ok=false
    fi

    if $ok; then
        echo "Validating GitHub PAT..."
        # Validate FAST and bounded. `gh auth login --with-token` can block for a
        # very long time on a bad token, while an authenticated API call fails in
        # about a second. Never enter the login flow with an unvalidated token.
        if GH_LOGIN=$(GH_TOKEN="$GITHUB_INSTALLER_PAT" timeout 15 gh api user --jq .login 2>/dev/null) \
           && [ -n "$GH_LOGIN" ]; then
            if printf '%s' "$GITHUB_INSTALLER_PAT" | timeout 30 gh auth login --with-token >/dev/null 2>&1; then
                GH_AUTH=true
                echo "Authenticated gh CLI with PAT as: $GH_LOGIN"
            else
                echo "Token is valid but 'gh auth login --with-token' did not complete."
                echo "  Workaround: export GH_TOKEN=<token> for gh commands."
                ok=false
            fi
        else
            echo "PAT rejected by GitHub (401 Bad credentials or no network)."
            echo "  Fix: setup.keys.root GITHUB_INSTALLER_PAT must be a TOKEN, not a"
            echo "       password/passphrase: classic ghp_... with repo, admin:public_key,"
            echo "       gist, workflow scopes, or a fine-grained token."
            ok=false
        fi

        if $GH_AUTH; then
            echo "Configuring git credential helper (root)..."
            if gh auth setup-git >/dev/null 2>&1; then
                echo "Git credential helper configured (gh)."
            else
                echo "Warning: gh auth setup-git failed (non-fatal if only using SSH remotes)."
            fi
        fi
    fi
fi

# ── The rest needs no API auth: run it even when the PAT is unusable ───────

# Configure git identity (best effort)
if [ -n "${GITHUB_INSTALLER_USERNAME:-}" ]; then
    git config --global user.name "$GITHUB_INSTALLER_USERNAME"
fi
if [ -n "${GITHUB_INSTALLER_EMAIL:-}" ]; then
    git config --global user.email "$GITHUB_INSTALLER_EMAIL"
fi

# Upload root's SSH public key (this DOES need API auth)
if $GH_AUTH; then
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
else
    echo "Skipping SSH key upload: gh is not authenticated (needs a valid PAT)."
fi

# Explicitly load root's SSH key into the agent right now (no API auth needed)
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

# Pre-seed github.com host key to avoid an interactive prompt on first SSH
echo "Seeding github.com host key for root..."
ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null || true

# Informational SSH test (never fatal for this step)
echo "Testing GitHub SSH connectivity (ssh -T git@github.com)..."
if timeout 12 ssh -T git@github.com 2>&1 | grep -qi "successfully authenticated"; then
    echo "GitHub SSH authentication test passed."
else
    echo "GitHub SSH test did not confirm: the public key is not registered on the"
    echo "account yet, or was just added (propagation can take a minute). Add it at"
    echo "https://github.com/settings/keys using:"
    for pub in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub /root/.ssh/id_ecdsa.pub; do
        [ -f "$pub" ] || continue
        sed -e 's/^/    /' "$pub"
        break
    done
fi

# Verify the credential helper (only meaningful when gh is authenticated)
if $GH_AUTH; then
    CRED_HELPER=$(git config --global --get-urlmatch credential.helper https://github.com 2>/dev/null)
    if [ -n "$CRED_HELPER" ]; then
        echo "Git credential helper confirmed for github.com: $CRED_HELPER"
    else
        echo "WARNING: No git credential helper detected. HTTPS git operations may prompt for password."
        echo "         Run 'gh auth setup-git' to fix."
    fi
fi

if $ok; then
    echo "SUCCESS: GitHub SSH (gh auth + optional key upload) configured."
    exit 0
else
    echo "ERROR: GitHub setup incomplete — fix GITHUB_INSTALLER_PAT in setup.keys.root"
    echo "       (must be a token, not a passphrase) and re-run steps/github-ssh.sh."
    exit 1
fi
