#!/bin/bash
# steps/pi-clean-reinstall.sh
# Fresh pi install from scratch — no Kitty protocol patch, no wrapper.
#
# Installs: pi binary, pi-hashline-edit, readonly-mode extension, and
# root config (settings.json, trust.json, auth.json).
#
# Idempotent: if pi is already installed and the Kitty flags are unpatched (7),
# the step skips the reinstall. Use FORCE=1 to reinstall anyway.
#
# Prerequisites:
#   - Internet access
#   - DEEPSEEK_API_KEY in setup.keys.root (or set in environment)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "PI CLEAN REINSTALL (no Kitty patch)"
echo "*****************************************************"

# ------------------------------------------------------------------
# Determine if we need to do anything
# ------------------------------------------------------------------
NEED_INSTALL=false

# Check 1: is pi binary present?
if ! command -v pi >/dev/null 2>&1; then
    echo "pi binary not found — will install."
    NEED_INSTALL=true
fi

# Check 2: is the Kitty flags patch applied? (5 = patched, 7 = unpatched)
if ! $NEED_INSTALL; then
    PATCHED=$(find /usr/local/node-v* /usr/lib64/node_modules \
        -path '*/pi-tui/dist/terminal.js' 2>/dev/null \
        -exec grep -lF 'DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS = 5' {} \; 2>/dev/null | wc -l)
    if [ "$PATCHED" -gt 0 ]; then
        echo "Kitty flags are patched (5) — will reinstall to get unpatched value (7)."
        NEED_INSTALL=true
    fi
fi

# Check 3: force flag
if [ "${FORCE:-0}" = "1" ]; then
    echo "FORCE=1 — will reinstall regardless."
    NEED_INSTALL=true
fi

if ! $NEED_INSTALL; then
    echo "pi already installed and Kitty flags are unpatched (7). Nothing to do."
    echo "SUCCESS: pi clean install verified."
    exit 0
fi

# ------------------------------------------------------------------
# 1. Wipe old pi artifacts
# ------------------------------------------------------------------
echo ""
echo "1. Wiping old pi artifacts..."
rm -rf /root/.local/share/pi-node 2>/dev/null || true
# Remove any existing pi-tui that has the patched flags
find /usr/local/node-v* /usr/lib64/node_modules \
    -maxdepth 0 -name '@earendil-works' -exec rm -rf {} \; 2>/dev/null || true
echo "   done."

# ------------------------------------------------------------------
# 2. Install pi from scratch
# ------------------------------------------------------------------
echo ""
echo "2. Installing pi from scratch..."
if curl -fsSL https://pi.dev/install.sh | sh 2>&1; then
    echo "   pi installed: $(pi --version 2>/dev/null || echo 'ok')"
else
    echo "ERROR: pi installation failed."
    exit 1
fi

# ------------------------------------------------------------------
# 3. Install pi-hashline-edit
# ------------------------------------------------------------------
echo ""
echo "3. Installing pi-hashline-edit..."
if pi install npm:pi-hashline-edit 2>&1; then
    echo "   pi-hashline-edit installed."
else
    echo "ERROR: pi install npm:pi-hashline-edit failed."
    exit 1
fi

# ------------------------------------------------------------------
# 4. Deploy root config
# ------------------------------------------------------------------
echo ""
echo "4. Deploying pi config for root..."
mkdir -p /root/.pi/agent /root/.pi/extensions 2>/dev/null || true

# settings.json
if [ -f "$REPO_DIR/dotfiles/pi/agent/settings.json" ]; then
    cp "$REPO_DIR/dotfiles/pi/agent/settings.json" /root/.pi/agent/settings.json
    echo "   settings.json deployed."
else
    echo "   WARNING: settings.json not found in repo; skipping."
fi

# trust.json
if [ -f "$REPO_DIR/dotfiles/pi/agent/trust.json" ]; then
    cp "$REPO_DIR/dotfiles/pi/agent/trust.json" /root/.pi/agent/trust.json
    echo "   trust.json deployed."
else
    echo "   WARNING: trust.json not found in repo; skipping."
fi

# auth.json
KEYS_FILE="$REPO_DIR/setup.keys.root"
if [ -f "$KEYS_FILE" ]; then
    # shellcheck disable=SC1090
    . "$KEYS_FILE"
fi
if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    cat > /root/.pi/agent/auth.json << AUTHJSON
{
  "xai": {
    "type": "api_key",
    "key": ""
  },
  "deepseek": {
    "type": "api_key",
    "key": "$DEEPSEEK_API_KEY"
  }
}
AUTHJSON
    chmod 600 /root/.pi/agent/auth.json
    echo "   auth.json deployed (DEEPSEEK_API_KEY from setup.keys.root)."
else
    echo "   WARNING: DEEPSEEK_API_KEY not set; auth.json not created."
fi

# ------------------------------------------------------------------
# 5. Install readonly-mode extension
# ------------------------------------------------------------------
echo ""
echo "5. Installing readonly-mode extension..."
if [ -f "$REPO_DIR/dotfiles/pi/readonly-mode.ts" ]; then
    cp "$REPO_DIR/dotfiles/pi/readonly-mode.ts" /root/.pi/extensions/readonly-mode.ts
    if pi install /root/.pi/extensions/readonly-mode.ts 2>&1; then
        echo "   readonly-mode extension registered."
    else
        echo "   ERROR: pi install readonly-mode.ts failed."
        exit 1
    fi
else
    echo "   ERROR: readonly-mode.ts not found in repo."
    exit 1
fi

echo ""
echo "SUCCESS: pi clean reinstall complete."
echo "  pi version: $(pi --version 2>/dev/null || echo 'unknown')"
echo "  Config:     /root/.pi/agent/"
echo "  Extensions: /root/.pi/extensions/"
exit 0
