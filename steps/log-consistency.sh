#!/bin/bash
# steps/log-consistency.sh — unified session log directory
#
# Creates /var/log/sessions with sticky, world-writable permissions so all
# users (root, rs, etc.) write session logs to the same place.
# Then re-deploys all scripts that use the new LOG_DIR.
#
# Idempotent: safe to run multiple times.

set -euo pipefail

REPO_DIR="${REPO_DIR:-/root/Development/slackware-installer-for-rs}"

# ── 1. Ensure /var/log/sessions exists with correct permissions ──────────
echo "── log directory ──"
if [ -d /var/log/sessions ] && [ "$(stat -c '%a' /var/log/sessions 2>/dev/null)" = "1777" ]; then
    echo "  /var/log/sessions already exists with 1777 permissions"
else
    mkdir -p /var/log/sessions
    chmod 1777 /var/log/sessions
    echo "  Created /var/log/sessions (1777 sticky)"
fi

# ── 2. Deploy updated scripts ────────────────────────────────────────────
deploy() {
    local src="$1" dst="$2"
    if [ ! -f "$src" ]; then
        echo "  SKIP: source not found — $src"
        return
    fi
    cp "$src" "$dst"
    chmod +x "$dst"
    echo "  Deployed: $dst"
}

echo "── session scripts ──"
deploy "$REPO_DIR/scripts/dwm-start.sh"      /usr/local/bin/dwm-start
deploy "$REPO_DIR/scripts/dwm-status.sh"     /usr/local/bin/dwm-status
deploy "$REPO_DIR/scripts/dwl-start.sh"      /usr/local/bin/dwl-start
deploy "$REPO_DIR/scripts/dwl-status.sh"     /usr/local/bin/dwl-status

echo "── service scripts ──"
deploy "$REPO_DIR/scripts/net-watch.sh"      /usr/local/bin/net-watch
deploy "$REPO_DIR/scripts/vnc.sh"            /usr/local/bin/vnc
deploy "$REPO_DIR/scripts/vpn.sh"            /usr/local/bin/vpn
deploy "$REPO_DIR/scripts/wifi-manager.sh"   /usr/local/bin/wifi-manager
deploy "$REPO_DIR/scripts/vpn-resume.sh"     /usr/local/bin/vpn-suspend

# Symlink for wifi-manager (legacy)
ln -sf /usr/local/bin/wifi-manager /usr/local/bin/wifi-manager.sh 2>/dev/null || true
ln -sf /usr/local/bin/net-watch /usr/local/bin/net-watch.sh 2>/dev/null || true

echo ""
echo "Log consistency: all scripts now write to /var/log/sessions/"
echo "Done."
