#!/bin/bash
# steps/root-dotfiles.sh - ROOT SHELL DOTFILES (bashrc, bash_profile, bash_logout)
# Deploys root's shell config from repo templates.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "ROOT DOTFILES (bashrc, bash_profile, bash_logout)"
echo "*****************************************************"

ok=true

# bashrc
# bashrc — root
if cp "$REPO_DIR/dotfiles/shell/bashrc" /root/.bashrc 2>/dev/null; then
    echo "  bashrc deployed to /root."
else
    echo "  ERROR: could not copy bashrc to /root."
    ok=false
fi

# bashrc — /etc/skel (new-user template)
if cp "$REPO_DIR/dotfiles/shell/bashrc" /etc/skel/.bashrc 2>/dev/null; then
    echo "  bashrc deployed to /etc/skel."
else
    echo "  ERROR: could not copy bashrc to /etc/skel."
    ok=false
fi

# bash_profile
if cp "$REPO_DIR/dotfiles/shell/bash_profile" /root/.bash_profile 2>/dev/null; then
    echo "  bash_profile deployed."
else
    echo "  ERROR: could not copy bash_profile."
    ok=false
fi

# bash_logout
if cp "$REPO_DIR/dotfiles/shell/bash_logout" /root/.bash_logout 2>/dev/null; then
    echo "  bash_logout deployed."
else
    echo "  ERROR: could not copy bash_logout."
    ok=false
fi

if $ok; then
    echo "SUCCESS: Root dotfiles configured."
    exit 0
else
    echo "ERROR: Root dotfiles setup encountered errors."
    exit 1
fi
