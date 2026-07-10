#!/bin/bash
# lib/patch-pi-kitty-flags.sh
# Idempotent: reduces Kitty keyboard protocol flags 7 → 5.
# Flag 2 (report key press/repeat/release) causes some terminals to emit
# raw 0x7f/0x09/0x0d on keyup for backspace/tab/enter. Removing it
# prevents the double-fire entirely.
#
# Version-resilient: searches all known pi installation paths.
set -euo pipefail

find_pi_files() {
    local glob="$1"
    find /usr/local/node-v* /usr/lib64/node_modules \
        "${HOME}/.local/share/pi-node" 2>/dev/null \
        -path "$glob" 2>/dev/null || true
}

changed=0
skipped=0
while IFS= read -r f; do
    [ -z "$f" ] && continue

    # Already patched?
    if grep -qF 'DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS = 5' "$f" 2>/dev/null; then
        skipped=$((skipped + 1))
        continue
    fi

    # Check that the target line actually exists
    if ! grep -qF 'DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS = 7' "$f" 2>/dev/null; then
        echo "patch-pi-kitty-flags: WARNING: $f found but value is neither 5 nor 7 — skipping"
        continue
    fi

    echo "patch-pi-kitty-flags: setting Kitty flags 7 → 5 in $f"
    cp "$f" "$f.bak-$(date +%Y%m%d-%H%M%S)"
    sed -i 's/DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS = 7/DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS = 5/' "$f"

    # Verify
    if grep -qF 'DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS = 5' "$f"; then
        echo "patch-pi-kitty-flags: verified"
        changed=$((changed + 1))
    else
        echo "patch-pi-kitty-flags: FAILED verification for $f" >&2
    fi
done < <(find_pi_files "*/pi-tui/dist/terminal.js")

echo "patch-pi-kitty-flags: $changed changed, $skipped already patched"
