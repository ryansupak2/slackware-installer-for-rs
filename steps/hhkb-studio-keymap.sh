#!/bin/bash
# steps/hhkb-studio-keymap.sh — HHKB Studio keymap (touch strip disabled)
#
# IDEMPOTENT: writes the keymap with touch-strip scancodes zeroed to the
# HHKB Studio keyboard. Detects if already applied by reading back the
# current profile and comparing touch-strip positions.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "HHKB Studio Keymap (touch strip disabled)"
echo "*****************************************************"

# Check prerequisites
HHKB_TOOLS=/usr/local/bin/hhkb-studio-tools
if [ ! -x "$HHKB_TOOLS" ]; then
    echo "ERROR: hhkb-studio-tools not installed. Run steps/hhkb-studio-tools.sh first."
    exit 1
fi

# Verify keyboard is connected
if ! "$HHKB_TOOLS" info 2>/dev/null | grep -q "Product name: HHKB-Studio"; then
    echo "ERROR: HHKB Studio not detected. Is it connected?"
    exit 1
fi

# Check if touch strip is already disabled
CURRENT=/tmp/hhkb-check-$$.toml
"$HHKB_TOOLS" read-profile -o "$CURRENT" 2>/dev/null
if python3 -c "
import toml
data = toml.load('$CURRENT')
codes = data['layers'][0]['scancodes']
# Touch strip positions: 86(Up),87(Down),101(Left),102(Right),116(MwUp),117(MwDn)
ts_pos = [86,87,101,102,116,117]
all_zero = all(codes[p] == 0 for p in ts_pos)
exit(0 if all_zero else 1)
" 2>/dev/null; then
    echo "Touch strip already disabled. Nothing to do."
    rm -f "$CURRENT"
    exit 0
fi
rm -f "$CURRENT"

# Write the keymap with touch strip disabled
KEYMAP="$REPO_DIR/dotfiles/configs/hhkb-studio-keymap.toml"
if [ ! -f "$KEYMAP" ]; then
    echo "ERROR: keymap file not found at $KEYMAP"
    exit 1
fi

echo "Writing keymap (touch strip disabled)..."
"$HHKB_TOOLS" write-profile -i "$KEYMAP" || {
    echo "ERROR: failed to write keymap"
    exit 1
}

echo "SUCCESS: HHKB keymap updated — touch strip disabled."
exit 0
