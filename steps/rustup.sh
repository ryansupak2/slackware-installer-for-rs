#!/bin/bash
# steps/rustup.sh — Rust toolchain via rustup
#
# IDEMPOTENT: safe to run multiple times. Skips if rustup + stable
# toolchain are already installed.
#
# Installs:
#   /usr/local/bin/rustup        — Rust toolchain installer
#   ~/.cargo/bin/cargo           — latest stable cargo
#   ~/.cargo/bin/rustc           — latest stable rustc
#
# After install, cargo/rustc are available via ~/.cargo/bin.
# Source ~/.cargo/env or add ~/.cargo/bin to PATH.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "Rustup (Rust toolchain installer)"
echo "*****************************************************"

RUSTUP_BIN=/usr/local/bin/rustup
CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
CARGO_BIN="$CARGO_HOME/bin/cargo"
RUSTC_BIN="$CARGO_HOME/bin/rustc"

# ── Already installed? ──────────────────────────────────────────

if [ -x "$RUSTUP_BIN" ] && [ -x "$CARGO_BIN" ] && [ -x "$RUSTC_BIN" ]; then
    echo "rustup + stable toolchain already installed."
    "$RUSTC_BIN" --version 2>&1
    exit 0
fi

# ── Install rustup ────────────────────────────────────────────────

if [ ! -x "$RUSTUP_BIN" ]; then
    echo "Downloading and installing rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --default-toolchain stable --no-modify-path 2>&1 || {
        echo "ERROR: rustup install failed"
        exit 1
    }

    # Move rustup binary to /usr/local/bin for system-wide access
    if [ -x "$CARGO_HOME/bin/rustup" ]; then
        cp "$CARGO_HOME/bin/rustup" "$RUSTUP_BIN"
        chmod 755 "$RUSTUP_BIN"
    fi
else
    echo "rustup already installed, updating toolchain..."
fi

# ── Ensure stable toolchain ───────────────────────────────────────

export PATH="$CARGO_HOME/bin:$PATH"
export RUSTUP_HOME="$CARGO_HOME"

if [ -x "$RUSTUP_BIN" ]; then
    "$RUSTUP_BIN" update stable 2>&1 || true
fi

# ── Verify ────────────────────────────────────────────────────────

if [ -x "$CARGO_BIN" ] && [ -x "$RUSTC_BIN" ]; then
    echo "SUCCESS: Rust toolchain installed."
    echo "  rustc: $("$RUSTC_BIN" --version)"
    echo "  cargo: $("$CARGO_BIN" --version)"
    echo ""
    echo "  Add to PATH: export PATH=\"\$HOME/.cargo/bin:\$PATH\""
    exit 0
else
    echo "ERROR: toolchain not found after install"
    exit 1
fi
