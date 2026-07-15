#!/bin/bash
# steps/inkscape.sh - INKSCAPE (vector graphics editor)
# Uses pre-built binary from alienBOB's repository

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "INKSCAPE (vector graphics editor)"
echo "*****************************************************"

# GraphicsMagick is a runtime dependency of the pre-built binary
# tcl is a Slackware package, GraphicsMagick is SBo
install_pkg "tcl" || { echo "ERROR: tcl install failed"; exit 1; }
install_sbo "GraphicsMagick" || { echo "ERROR: GraphicsMagick install failed"; exit 1; }

if [ -x /usr/bin/inkscape ]; then
    echo "inkscape already installed: $(which inkscape)"
else
    INKSCAPE_URL="https://slackware.uk/people/alien/sbrepos/15.0/x86_64/inkscape/inkscape-1.2.2-x86_64-1alien.txz"
    echo "Downloading inkscape 1.2.2 (pre-built)..."
    if wget --show-progress -q "$INKSCAPE_URL" -O /tmp/inkscape.txz; then
        installpkg /tmp/inkscape.txz && rm -f /tmp/inkscape.txz
        echo "inkscape installed."
    else
        echo "ERROR: could not download inkscape."
        exit 1
    fi
fi

echo "SUCCESS: inkscape installed."
exit 0
