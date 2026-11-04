#!/bin/bash
# steps/hhkb-studio-keymap.sh — HHKB Studio keymap (all sliders disabled)
#
# IDEMPOTENT: writes the keymap with all slider/gesture-pad scancodes
# zeroed to the HHKB Studio keyboard. Detects if already applied by reading
# back the current profile and comparing slider positions across all layers.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "HHKB Studio Keymap (all sliders disabled)"
echo "*****************************************************"

# Check prerequisites
HHKB_TOOLS=/usr/local/bin/hhkb-studio-tools
if [ ! -x "$HHKB_TOOLS" ]; then
    echo "ERROR: hhkb-studio-tools not installed. Run steps/hhkb-studio-tools.sh first."
    exit 1
fi

# Find the HHKB device (try hidraw0-5)
HHKB_DEVICE="${HHKB_DEVICE:-}"
if [ -z "$HHKB_DEVICE" ]; then
    for dev in /dev/hidraw{0,1,2,3,4,5}; do
        if timeout 3 "$HHKB_TOOLS" info --device "$dev" 2>/dev/null | grep -q "Product name: HHKB-Studio"; then
            HHKB_DEVICE="$dev"
            break
        fi
    done
fi
if [ -z "$HHKB_DEVICE" ]; then
    echo "ERROR: HHKB Studio not detected. Is it connected?"
    echo "  Try setting HHKB_DEVICE=/dev/hidrawN"
    exit 1
fi
echo "Using device: $HHKB_DEVICE"

# Check if sliders already disabled (no 24460/24461 = Alt+Tab gesture actions)
CURRENT=/tmp/hhkb-check-$$.toml
"$HHKB_TOOLS" read-profile --device "$HHKB_DEVICE" -o "$CURRENT" 2>/dev/null
if python3 -c "
import toml
data = toml.load('$CURRENT')
for layer in data['layers']:
    if 24460 in layer['scancodes'] or 24461 in layer['scancodes']:
        exit(1)
exit(0)
" 2>/dev/null; then
    echo "All sliders already disabled. Nothing to do."
    rm -f "$CURRENT"
    exit 0
fi
rm -f "$CURRENT"

# Write the keymap with sliders disabled
KEYMAP="$REPO_DIR/dotfiles/configs/hhkb-studio-keymap.toml"
if [ ! -f "$KEYMAP" ]; then
    echo "ERROR: keymap file not found at $KEYMAP"
    exit 1
fi

echo "Writing keymap (all sliders disabled)..."
"$HHKB_TOOLS" write-profile --device "$HHKB_DEVICE" -i "$KEYMAP" || {
    echo "ERROR: failed to write keymap"
    exit 1
}

echo "SUCCESS: HHKB keymap updated — all sliders disabled."
exit 0
