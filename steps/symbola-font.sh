#!/bin/bash
# steps/symbola-font.sh — SYMBOLA FONT (complete monochrome emoji coverage)
# Extracts Symbola.otf from the source PDF using pdfdetach (poppler).
# No fontforge needed — OTF works directly with fontconfig.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "SYMBOLA FONT (monochrome emoji)"
echo "*****************************************************"

ok=true

# Already installed?
if [ -f /usr/share/fonts/OTF/Symbola.otf ]; then
    echo "Symbola already installed — skipping"
    exit 0
fi

# Dependencies: poppler (provides pdfdetach)
echo "Installing poppler (for pdfdetach)..."
install_pkg "poppler" || ok=false

if $ok; then
    WORKDIR=/tmp/symbola-build
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"

    # Download Symbola PDF from web.archive.org (version 14.00)
    SYMBOLA_URL="https://web.archive.org/web/20240107144224/https://dn-works.com/wp-content/uploads/2021/UFAS121921/Symbola.pdf"
    LICENSE_URL="https://web.archive.org/web/20240305062409/https://dn-works.com/wp-content/uploads/2021/UFAS121921/License.pdf"

    echo "Downloading Symbola.pdf..."
    if ! curl -sL -o Symbola.pdf "$SYMBOLA_URL"; then
        echo "ERROR: Failed to download Symbola.pdf"
        ok=false
    fi

    if $ok && [ ! -s Symbola.pdf ]; then
        echo "ERROR: Symbola.pdf is empty"
        ok=false
    fi

    if $ok; then
        echo "Extracting embedded OTF..."
        pdfdetach -saveall Symbola.pdf 2>/dev/null

        if [ ! -f Symbola.otf ]; then
            echo "ERROR: Failed to extract Symbola.otf from PDF"
            ls -la "$WORKDIR"
            ok=false
        fi
    fi

    if $ok; then
        echo "Installing Symbola.otf..."
        mkdir -p /usr/share/fonts/OTF
        install -m 0644 Symbola.otf /usr/share/fonts/OTF/

        # Download license for documentation
        curl -sL -o License.pdf "$LICENSE_URL" 2>/dev/null || true
        mkdir -p /usr/doc/symbola-font-14.00
        cp License.pdf /usr/doc/symbola-font-14.00/ 2>/dev/null || true

        # Update fontconfig cache
        fc-cache -f

        echo "SUCCESS: Symbola font installed."
        echo "  $(ls -la /usr/share/fonts/OTF/Symbola.otf | awk '{print $5}') bytes"
    fi

    rm -rf "$WORKDIR"
fi

if $ok; then
    exit 0
else
    echo "ERROR: Symbola font setup failed."
    exit 1
fi
