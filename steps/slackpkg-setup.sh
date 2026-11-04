#!/bin/bash
# steps/slackpkg-setup.sh - CORE: SLACKPKG MIRROR SETUP & SBOPKG

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

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

# --- 3. GnuPG: sbopkg verifies SBo tarballs with `gpg --verify` ---
# Slackware 15.0+ ships gpg1 (gnupg) and gpg2 (gnupg2) but NO plain `gpg`.
# Without a `gpg`, every SBo build fails with "GPG check FAILED!" and the
# package is never installed (this is what broke github-cli and git-lfs).
# The shim prefers gpg2 and falls back to gpg1 if gpg2's libs are broken.
if $ok; then
    echo "Configuring GnuPG for sbopkg verification..."
    if install -m 0755 "$REPO_DIR/scripts/gpg" /usr/local/bin/gpg; then
        echo "  /usr/local/bin/gpg deployed (gpg2 -> gpg1 fallback)"
    else
        echo "ERROR: could not deploy the gpg shim."
        ok=false
    fi
fi

if $ok; then
    if gpg --version >/dev/null 2>&1; then
        echo "  gpg: $(gpg --version | awk 'NR==1{print $1, $3}')"
    else
        echo "ERROR: no working GnuPG (tried gpg2, gpg1). Install gnupg or gnupg2."
        ok=false
    fi
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

# --- 6. SlackBuilds.org signing key ---
# sbopkg refuses to build unless the tarball's .asc verifies, so the SBo
# key must be in the keyring. --import is idempotent (same key, no change).
if $ok; then
    if gpg --list-keys 2>/dev/null | grep -q "SlackBuilds.org"; then
        echo "  SlackBuilds.org signing key already present."
    else
        echo "  Importing SlackBuilds.org signing key..."
        if wget -qO- --timeout=30 https://www.slackbuilds.org/GPG-KEY | gpg --import; then
            echo "  SBo signing key imported."
        else
            echo "ERROR: could not import the SBo signing key (sbopkg builds would fail)."
            ok=false
        fi
    fi
fi

# --- 7. Prove GPG verification works on the synced repo ---
if $ok; then
    for asc in /var/lib/sbopkg/SBo/*/CHECKSUMS.md5.asc; do
        [ -f "$asc" ] || continue
        if gpg --verify "$asc" >/dev/null 2>&1; then
            echo "  GPG verification OK: $asc"
        else
            echo "ERROR: GPG verification failed for $asc"
            ok=false
        fi
    done
fi

if $ok; then
    echo "SUCCESS: slackpkg mirror configured and sbopkg installed."
    exit 0
else
    echo "ERROR: slackpkg setup failed."
    exit 1
fi
