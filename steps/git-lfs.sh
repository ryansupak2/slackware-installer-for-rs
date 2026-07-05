#!/bin/bash
# steps/git-lfs.sh - GIT LARGE FILE STORAGE (GIT LFS)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "GIT LARGE FILE STORAGE (GIT LFS)"
echo "*****************************************************"

ok=true

echo "Installing Git LFS via sbopkg/slackpkg..."
if ! install_sbo "git-lfs"; then
    echo "ERROR: failed to install git-lfs via sbopkg/slackpkg."
    ok=false
fi

if $ok; then
    echo "Setting up Git LFS globally..."
    if ! git lfs install; then
        echo "ERROR: git lfs install failed."
        ok=false
    fi
fi

if $ok; then
    echo "SUCCESS: Git LFS installed and set up."
    exit 0
else
    echo "ERROR: Git LFS setup encountered errors."
    exit 1
fi
