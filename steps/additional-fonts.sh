#!/bin/bash
# steps/additional-fonts.sh - ADDITIONAL FONTS

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "ADDITIONAL FONTS                                     "
echo "*****************************************************"

ok=true

echo "Installing Additional Fonts..."
install_pkg "fontconfig dejavu-fonts-ttf" || ok=false
install_sbo "noto-emoji noto-extra-ttf adobe-source-han-sans-fonts" || ok=false
mkdir -p /usr/share/fonts/TTF
for ttf in "$REPO_DIR"/fonts/BerkeleyMono-*.ttf; do
    if [ -f "$ttf" ]; then
        if ! cp "$ttf" /usr/share/fonts/TTF/; then
            ok=false
        fi
    fi
done

# Install Berkeley Mono fontconfig fallback (idempotent copy)
mkdir -p /etc/fonts/conf.d
if [ -f "$REPO_DIR/dotfiles/configs/99-berkeley-mono-fallback.conf" ]; then
    cp "$REPO_DIR/dotfiles/configs/99-berkeley-mono-fallback.conf" /etc/fonts/conf.d/99-berkeley-mono-fallback.conf
fi

if $ok; then
    fc-cache -fv
fi

if $ok; then
    echo "SUCCESS: Additional fonts installed and font cache updated."
    exit 0
else
    echo "ERROR: Additional Fonts setup encountered errors."
    exit 1
fi
