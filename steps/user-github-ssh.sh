#!/bin/bash
# steps/user-github-ssh.sh - GITHUB FOR A DESKTOP USER (SSH-first)
#
# Same design as steps/github-ssh.sh for root: SSH is what `git push` needs,
# so git identity, the URL rewrite, known_hosts and the SSH test are configured
# and verified WITHOUT a token. The PAT is optional and only used to:
#   (a) log `gh` in for that user (credential helper), and
#   (b) upload the user's public key through the API (admin:public_key scope).
#
# A dead/absent PAT therefore must not leave the user without working git over
# SSH — which is exactly what this step used to do (everything was gated on
# PAT_OK, so rs ended up with no .gitconfig, no known_hosts and no key upload
# while root worked fine over SSH).
#
# Idempotent.

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
echo "GITHUB (SSH + optional PAT) FOR $TARGET_USER"
echo "*****************************************************"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: user-github-ssh.sh must run as root"
    exit 1
fi
id "$TARGET_USER" >/dev/null 2>&1 || {
    echo "ERROR: user $TARGET_USER does not exist"
    exit 1
}

HOME_TARGET=$(eval echo "~$TARGET_USER")

# ── Load keys: per-user file first, then the shared root file ──────────
KEY_FILE="$REPO_DIR/setup.keys.$TARGET_USER"
[ -f "$KEY_FILE" ] || KEY_FILE="$REPO_DIR/setup.keys.root"
if [ -f "$KEY_FILE" ]; then
    echo "  keys   : $KEY_FILE"
    while IFS='=' read -r key value; do
        case "$key" in ''|'#'*) continue ;; esac
        export "$key=$value"
    done < "$KEY_FILE"
fi

GIT_NAME="${GITHUB_INSTALLER_USERNAME:-}"
GIT_EMAIL="${GITHUB_INSTALLER_EMAIL:-}"
PUBKEY=""
for k in "$HOME_TARGET/.ssh/id_ed25519.pub" "$HOME_TARGET/.ssh/id_rsa.pub" \
         "$HOME_TARGET/.ssh/id_ecdsa.pub"; do
    [ -f "$k" ] && { PUBKEY="$k"; break; }
done

as_user() { su - "$TARGET_USER" -c "$1"; }

# ── 1. git identity (same as root's ~/.gitconfig) ─────────────────────
echo "Configuring git for $TARGET_USER..."
if [ -n "$GIT_NAME" ]; then
    as_user "git config --global user.name \"$GIT_NAME\"" 2>/dev/null \
        && echo "  user.name  = $GIT_NAME"
fi
if [ -n "$GIT_EMAIL" ]; then
    as_user "git config --global user.email \"$GIT_EMAIL\"" 2>/dev/null \
        && echo "  user.email = $GIT_EMAIL"
fi

# git-lfs filter block: root gets this from `git lfs install`; do the same so
# the per-user .gitconfig matches root's.
if command -v git-lfs >/dev/null 2>&1; then
    as_user 'git lfs install' >/dev/null 2>&1 || true
fi

# https://github.com/... resolves to the SSH remote, exactly like root's config
if [ "$(as_user 'git config --global --get url.git@github.com:.insteadOf' 2>/dev/null)" != "https://github.com/" ]; then
    as_user 'git config --global url."git@github.com:".insteadOf "https://github.com/"' 2>/dev/null || true
    echo "  url rewrite: https://github.com/ -> git@github.com:"
fi

# ── 2. known_hosts (idempotent append) ────────────────────────────────
if ! as_user "grep -q '^github.com ' \"$HOME_TARGET/.ssh/known_hosts\"" 2>/dev/null; then
    as_user 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keyscan -t ed25519,rsa github.com >> ~/.ssh/known_hosts 2>/dev/null' 2>/dev/null || true
    echo "  github.com host key seeded in ~/.ssh/known_hosts"
fi

# ── 3. Verify SSH — this is the goal, independent of any token ────────
SSH_OK=false
echo "Testing GitHub SSH for $TARGET_USER..."
if as_user 'timeout 12 ssh -T git@github.com 2>&1' | grep -qi 'successfully authenticated'; then
    SSH_OK=true
    echo "  GitHub SSH authentication passed."
fi

# ── 4. Optional PAT: log gh in + upload the key ───────────────────────
GH_OK=false
PAT_OK=false
if [ -n "${GITHUB_INSTALLER_PAT:-}" ] && command -v gh >/dev/null 2>&1; then
    echo "Checking GITHUB_INSTALLER_PAT..."
    if GH_LOGIN=$(printf '%s\n' "$GITHUB_INSTALLER_PAT" | \
                  as_user 'IFS= read -r GH_TOKEN; export GH_TOKEN; timeout 15 gh api user --jq .login' 2>/dev/null) \
       && [ -n "$GH_LOGIN" ]; then
        PAT_OK=true
        echo "  token valid for: $GH_LOGIN"
        if printf '%s' "$GITHUB_INSTALLER_PAT" | \
           as_user 'IFS= read -r t; printf "%s" "$t" | timeout 30 gh auth login --with-token' >/dev/null 2>&1; then
            GH_OK=true
            echo "  gh authenticated for $TARGET_USER"
            as_user 'gh auth setup-git' >/dev/null 2>&1 && echo "  git credential helper configured (gh)"
        else
            echo "  WARNING: token is valid but 'gh auth login --with-token' failed"
        fi

        if [ -n "$PUBKEY" ] && ! $SSH_OK; then
            TITLE="${TARGET_USER}@$(hostname 2>/dev/null || echo slackware)-$(date +%Y-%m-%d)"
            if as_user "gh ssh-key add \"$PUBKEY\" --title \"$TITLE\"" >/dev/null 2>&1; then
                echo "  uploaded $PUBKEY to GitHub ($TITLE)"
                # give GitHub a moment, then re-test
                sleep 2
                if as_user 'timeout 12 ssh -T git@github.com 2>&1' | grep -qi 'successfully authenticated'; then
                    SSH_OK=true
                    echo "  GitHub SSH authentication passed after upload."
                fi
            else
                echo "  WARNING: could not upload the key (needs admin:public_key scope)"
            fi
        fi
    else
        echo "  WARNING: GITHUB_INSTALLER_PAT is NOT valid (401 Bad credentials/expired)."
        echo "           gh stays logged out and the key cannot be uploaded automatically."
        echo "           This does not stop 'git push' over SSH once the key is added."
    fi
elif [ -z "${GITHUB_INSTALLER_PAT:-}" ]; then
    echo "No GITHUB_INSTALLER_PAT found — skipping gh login/key upload (SSH only)."
else
    echo "gh not available — skipping PAT auth (SSH only)."
fi

# ── Result: SSH is the success criterion, like steps/github-ssh.sh ────
if $SSH_OK; then
    echo "SUCCESS: GitHub works for $TARGET_USER over SSH (no token needed)."
    if ! $PAT_OK; then
        echo "  note: gh/API actions need a valid GITHUB_INSTALLER_PAT; git push does not."
    fi
    exit 0
fi

echo "ERROR: no working GitHub credential for $TARGET_USER."
if [ -n "$PUBKEY" ]; then
    echo "  Add this public key once at https://github.com/settings/keys :"
    sed -e 's/^/    /' "$PUBKEY"
    echo "  Then: TARGET_USER=$TARGET_USER REPO_DIR=$REPO_DIR bash $0"
else
    echo "  No public key found in $HOME_TARGET/.ssh/ — run steps/user-ssh.sh first."
fi
exit 1
