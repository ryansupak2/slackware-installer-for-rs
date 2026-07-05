#!/bin/bash
# lib/patch-pi-kitty-flags.sh
# Idempotent: reduces Kitty keyboard protocol flags 7 → 5.
# Flag 2 (report key press/repeat/release) causes some terminals to emit
# raw 0x7f/0x09/0x0d on keyup for backspace/tab/enter. Removing it
# prevents the double-fire entirely.
set -euo pipefail

find_pi_files() {
    local glob="$1"
    find /usr/local/node-v* /usr/lib64/node_modules /root/.local/share/pi-node \
        -path "$glob" 2>/dev/null || true
}

while IFS= read -r f; do
    [ -z "$f" ] && continue
    if grep -qF 'DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS = 5' "$f"; then
        continue
    fi
    echo "patch-pi-kitty-flags: setting Kitty flags 7 → 5 in $f"
    cp "$f" "$f.bak-$(date +%Y%m%d-%H%M%S)"
    sed -i 's/DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS = 7/DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS = 5/' "$f"
    echo "patch-pi-kitty-flags: done"
done < <(find_pi_files "*/pi-tui/dist/terminal.js")
