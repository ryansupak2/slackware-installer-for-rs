#!/bin/bash
# steps/slackpkg-setup.sh - CORE: SLACKPKG MIRROR SETUP & SBOPKG

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "CORE: SLACKPKG SETUP & SBOPKG"
echo "*****************************************************"
ok=true

# --- 1. Set mirror (MUST be first — slackpkg needs a mirror to reach) ---
echo "Setting slackpkg mirror..."
sed -i 's|^# https://mirrors.slackware.com/slackware/slackware64-15.0/|https://mirrors.slackware.com/slackware/slackware64-15.0/|' /etc/slackpkg/mirrors || ok=false

# --- 2. Update slackpkg ---
if $ok; then
    echo "Updating slackpkg..."
    slackpkg -batch=on update || ok=false
fi

# --- 3. Fix gpupg (fresh installs sometimes have stale keyring) ---
if $ok; then
    echo "Fixing package manager GPG keyring..."
    slackpkg -batch=on -default_answer=y remove gnupg2 2>/dev/null || true
    slackpkg -batch=on -default_answer=y install gnupg2 || ok=false
fi

# --- 4. Install sbopkg ---
if $ok; then
    echo "Installing sbopkg..."
    SBOPKG_VERSION="0.38.3"
    SBOPKG_URL="https://github.com/sbopkg/sbopkg/releases/download/${SBOPKG_VERSION}/sbopkg-${SBOPKG_VERSION}-noarch-1_wsr.tgz"
    if ! command -v sbopkg >/dev/null 2>&1; then
        if ! wget -q "$SBOPKG_URL" -O /tmp/sbopkg.tgz; then
            echo "ERROR: Failed to download sbopkg."
            ok=false
        else
            installpkg /tmp/sbopkg.tgz || ok=false
            rm -f /tmp/sbopkg.tgz
        fi
    else
        echo "sbopkg already installed."
    fi
fi

# --- 5. Sync sbopkg ---
if $ok; then
    echo "Syncing sbopkg repository..."
    sbopkg -r || { echo "WARNING: sbopkg sync failed (non-fatal)."; }
fi

if $ok; then
    echo "SUCCESS: slackpkg mirror configured and sbopkg installed."
    exit 0
else
    echo "ERROR: slackpkg setup failed."
    exit 1
fi
