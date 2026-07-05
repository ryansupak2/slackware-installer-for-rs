#!/bin/bash
# steps/inkscape.sh - INKSCAPE (vector graphics editor)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "INKSCAPE (vector graphics editor)                    "
echo "*****************************************************"

echo "Installing inkscape..."
if ! install_sbo "inkscape"; then
    echo "ERROR: inkscape install failed."
    exit 1
fi

echo "SUCCESS: inkscape installed."
exit 0
