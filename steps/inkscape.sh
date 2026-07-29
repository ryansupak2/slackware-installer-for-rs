#!/bin/bash
# steps/inkscape.sh - INKSCAPE (vector graphics editor)
# Uses pre-built binary and deps from alienBOB's repository

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "INKSCAPE (vector graphics editor)"
echo "*****************************************************"

ALIEN_BASE="https://slackware.uk/people/alien/sbrepos/15.0/x86_64"
ALIEN_DEPS="double-conversion gdl graphicsmagick libcdr potrace pstoedit python-cssselect python-lxml python-numpy scour"

# Install tcl from official Slackware
install_pkg "tcl" || { echo "ERROR: tcl install failed"; exit 1; }

# Install each alienBOB dependency
for dep in $ALIEN_DEPS; do
    if ls /var/log/packages/${dep}-* >/dev/null 2>&1; then
        echo "$dep already installed."
        continue
    fi
    # Find the correct package extension (.txz or .tgz)
    pkg_url=$(curl -sL "$ALIEN_BASE/$dep/" | grep -oP 'href="\K[^"]*\.(txz|tgz)"' | head -1 | tr -d '"')
    if [ -z "$pkg_url" ]; then
        echo "ERROR: could not find package for $dep"
        exit 1
    fi
    ext="${pkg_url##*.}"
    echo "Downloading $dep: $ALIEN_BASE/$dep/$pkg_url"
    wget --show-progress -q "$ALIEN_BASE/$dep/$pkg_url" -O /tmp/${dep}.${ext} || {
        echo "ERROR: could not download $dep"
        exit 1
    }
    installpkg /tmp/${dep}.${ext} || {
        echo "ERROR: installpkg failed for $dep"
        rm -f /tmp/${dep}.${ext}
        exit 1
    }
    rm -f /tmp/${dep}.${ext}
    echo "$dep installed."
done

# Install Inkscape itself
if [ -x /usr/bin/inkscape ]; then
    echo "inkscape already installed: $(which inkscape)"
else
    INKSCAPE_URL="$ALIEN_BASE/inkscape/inkscape-1.2.2-x86_64-1alien.txz"
    echo "Downloading inkscape 1.2.2 (pre-built)..."
    if wget --show-progress -q "$INKSCAPE_URL" -O /tmp/inkscape.txz; then
        installpkg /tmp/inkscape.txz && rm -f /tmp/inkscape.txz
        echo "inkscape installed."
    else
        echo "ERROR: could not download inkscape."
        exit 1
    fi
fi

# Verify shared library deps are satisfied
echo "Checking shared library dependencies..."
MISSING=$(ldd /usr/bin/inkscape 2>&1 | grep 'not found' || true)
if [ -n "$MISSING" ]; then
    echo "WARNING: some libraries still missing:"
    echo "$MISSING"
    echo "(inkscape may still fail to start)"
fi

# Quick-launch wrapper (draw → inkscape, closes terminal on launch)
cp "$REPO_DIR/scripts/draw" /usr/local/bin/draw
chmod +x /usr/local/bin/draw
echo "SUCCESS: /usr/local/bin/draw installed (alias: draw → inkscape)"

echo "SUCCESS: inkscape installed."
exit 0
