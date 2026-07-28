#!/bin/bash
# steps/hhkb-studio-tools.sh — HHKB Studio keymap CLI tool
#
# IDEMPOTENT: safe to run multiple times. Checks for existing binary
# and skips build if already installed.
#
# Installs:
#   /usr/local/bin/hhkb-studio-tools   — CLI for HHKB Studio keymap read/write

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "HHKB Studio Tools (keymap CLI)"
echo "*****************************************************"

BIN=/usr/local/bin/hhkb-studio-tools
SRC=/usr/local/src/hhkb-studio-tools

# ── Already installed? ──────────────────────────────────────────

if [ -x "$BIN" ]; then
    echo "hhkb-studio-tools already installed at $BIN"
    "$BIN" --help 2>&1 | head -1 || true
    exit 0
fi

# ── Prerequisites ────────────────────────────────────────────────

ok=true
install_pkg "git"   || ok=false

# Use rustup-installed cargo (~/.cargo/bin) if available;
# system cargo on Slackware 15.0 is too old (1.58).
CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export PATH="$CARGO_HOME/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: Rust/cargo is required. Run: REPO_DIR=$REPO_DIR bash $REPO_DIR/steps/rustup.sh"
    ok=false
fi

if ! $ok; then
    echo "ERROR: prerequisites missing"
    exit 1
fi

# ── Clone or update repo ─────────────────────────────────────────

mkdir -p /usr/local/src

if [ -d "$SRC" ]; then
    echo "Updating existing clone..."
    cd "$SRC" && git pull --ff-only 2>/dev/null || true
else
    echo "Cloning hhkb-studio-tools..."
    git clone --depth 1 https://github.com/yuja/hhkb-studio-tools "$SRC"
fi || { echo "ERROR: clone/update failed"; exit 1; }

# ── Build ─────────────────────────────────────────────────────────

cd "$SRC"
# Remove upstream lockfile in case format doesn't match our cargo
rm -f Cargo.lock
echo "Building hhkb-studio-tools (cargo release)..."
cargo build --release || { echo "ERROR: cargo build failed"; exit 1; }

# ── Install ───────────────────────────────────────────────────────

cp "$SRC/target/release/hhkb-studio-tools" "$BIN"
chmod 755 "$BIN"

# ── Verify ────────────────────────────────────────────────────────

if [ -x "$BIN" ]; then
    echo "SUCCESS: hhkb-studio-tools installed at $BIN"
    "$BIN" --help 2>&1 | head -1 || true
    exit 0
else
    echo "ERROR: binary not found after install"
    exit 1
fi
