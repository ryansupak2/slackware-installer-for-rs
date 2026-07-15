#!/bin/bash
# steps/brightness.sh - BRIGHTNESS (MONITOR AND KEYBOARD)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "BRIGHTNESS (MONITOR AND KEYBOARD)"
echo "*****************************************************"

ok=true
cd ~
if ! cp "$REPO_DIR/dotfiles/brightness/"* /usr/local/bin/ 2>/dev/null; then ok=false; fi
if $ok; then
    chmod 755 /usr/local/bin/brightness_*.sh 2>/dev/null || ok=false
fi

if $ok; then
    if ! cp "$REPO_DIR/dotfiles/kbd_backlight/"* /usr/local/bin/ 2>/dev/null; then ok=false; fi
    if $ok; then
        chmod 755 /usr/local/bin/kbd_backlight_*.sh 2>/dev/null || ok=false
    fi
fi

echo "Setting up keyboard backlight permissions..."
if $ok; then
    if ! cp "$REPO_DIR/dotfiles/udev/90-keyboard-backlight.rules" /etc/udev/rules.d/ 2>/dev/null; then ok=false; fi
    if $ok; then
        udevadm control --reload-rules 2>/dev/null || true
        udevadm trigger --subsystem-match=leds 2>/dev/null || true
    fi
fi

if $ok; then
    echo "SUCCESS: Brightness (monitor/keyboard) configured."
    exit 0
else
    echo "ERROR: could not configure brightness."
    exit 1
fi
