#!/bin/bash
# steps/xclick.sh — xclick helper for synthesizing mouse button events
#
# IDEMPOTENT: safe to run multiple times.
#
# Installs: /usr/local/bin/xclick — sends X mouse button clicks via XTest

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "xclick — XTest mouse button helper"
echo "*****************************************************"

BIN=/usr/local/bin/xclick

# ── Already installed? ──────────────────────────────────────────
if [ -x "$BIN" ]; then
    echo "xclick already installed at $BIN"
    exit 0
fi

# ── Prerequisites ────────────────────────────────────────────────
ok=true
install_pkg "libX11"     || ok=false
install_pkg "libXtst"    || ok=false
install_pkg "gcc"        || ok=false
if ! $ok; then
    echo "ERROR: prerequisites missing"
    exit 1
fi

# ── Build ─────────────────────────────────────────────────────────
SRC="$REPO_DIR/lib/xclick.c"
if [ ! -f "$SRC" ]; then
    echo "ERROR: source not found at $SRC"
    exit 1
fi

echo "Compiling xclick..."
gcc -O2 -o "$BIN" "$SRC" -lX11 -lXtst || { echo "ERROR: compile failed"; exit 1; }
chmod 755 "$BIN"

# ── Verify ────────────────────────────────────────────────────────
if [ -x "$BIN" ]; then
    echo "SUCCESS: xclick installed at $BIN"
    "$BIN" 2>&1 | head -1 || true
    exit 0
else
    echo "ERROR: binary not found after install"
    exit 1
fi
