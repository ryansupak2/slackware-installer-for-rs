#!/bin/bash
# lib/patch-pi-kitty-flags.sh
# Idempotent: reduces Kitty keyboard protocol flags 7 → 5.
# Flag 2 (report key press/repeat/release) causes some terminals to emit
# raw 0x7f/0x09 on keyup. Removing it prevents the double-fire entirely.
set -euo pipefail

TARGET=$(find /usr/local/node-v* -path "*/pi-tui/dist/terminal.js" 2>/dev/null | head -1)

if [ -z "$TARGET" ] || [ ! -f "$TARGET" ]; then
    TARGET=$(find /root/.local/share/pi-node -path "*/pi-tui/dist/terminal.js" 2>/dev/null | head -1)
fi

if [ -z "$TARGET" ] || [ ! -f "$TARGET" ]; then
    echo "patch-pi-kitty-flags: terminal.js not found — skipping"
    exit 0
fi

if grep -qF 'DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS = 5' "$TARGET"; then
    exit 0
fi

echo "patch-pi-kitty-flags: setting Kitty flags 7 → 5 in $TARGET"
cp "$TARGET" "$TARGET.bak-$(date +%Y%m%d-%H%M%S)"
sed -i 's/DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS = 7/DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS = 5/' "$TARGET"
echo "patch-pi-kitty-flags: done"
