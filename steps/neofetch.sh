#!/bin/bash
# steps/neofetch.sh - NEOFETCH

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "NEOFETCH                                           "
echo "*****************************************************"

ok=true

echo "Installing neofetch..."
if curl -fsSL https://raw.githubusercontent.com/dylanaraps/neofetch/master/neofetch -o /usr/local/bin/neofetch 2>/dev/null; then
    chmod +x /usr/local/bin/neofetch
    ln -sf /usr/local/bin/neofetch /usr/bin/neofetch 2>/dev/null || true
else
    echo "ERROR: failed to install neofetch."
    ok=false
fi

# Silent side effects so the GPU line works with the default splash for root.
install_pkg "pciutils" || true
mkdir -p /root/.config/neofetch 2>/dev/null || true
cp "$REPO_DIR/dotfiles/neofetch/config.conf" /root/.config/neofetch/config.conf 2>/dev/null || true
cp "$REPO_DIR/dotfiles/neofetch/bobdobbs.txt" /root/.config/neofetch/bobdobbs.txt 2>/dev/null || true

if $ok; then
    echo "SUCCESS: Neofetch installed."
    exit 0
else
    echo "ERROR: Neofetch setup encountered errors."
    exit 1
fi
