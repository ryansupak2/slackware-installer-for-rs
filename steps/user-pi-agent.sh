#!/bin/bash
# steps/user-pi-agent.sh
# Configures pi-coding-agent for a desktop user.
#
# The target user (TARGET_USER) is set by post-install-user.sh.
# Requires REPO_DIR to be set (also handled by the caller).
#
# Keys are read from REPO_DIR/setup.keys.rs (manually copied from
# setup.keys.root by the admin), NOT from setup.keys.root.
#
# Copies settings.json, trust.json, auth.json (with keys filled in),
# and the readonly-mode extension from dotfiles/pi/ into the user's
# ~/.pi/ directory, registers it with pi install, then chowns everything.

set -e

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
if [ -z "$TARGET_USER" ]; then
    echo "ERROR: TARGET_USER is not set. Run this via post-install-user.sh." >&2
    exit 1
fi

KEYS_FILE="$REPO_DIR/setup.keys.rs"
if [ ! -f "$KEYS_FILE" ]; then
    echo "ERROR: $KEYS_FILE not found."
    echo "       Copy setup.keys.root to setup.keys.rs and edit the key values."
    echo "       (The file must exist even if keys are blank — placeholder auth.json will be created.)"
    exit 1
fi

# Source the keys file to get XAI_API_KEY and DEEPSEEK_API_KEY
# shellcheck disable=SC1090
source "$KEYS_FILE"

HOME_TARGET=$(eval echo "~$TARGET_USER")
PI_DIR="$HOME_TARGET/.pi/agent"
EXT_DIR="$HOME_TARGET/.pi/extensions"

echo "Setting up pi-coding-agent for $TARGET_USER..."
echo "  Home: $HOME_TARGET"
echo "  Config dir: $PI_DIR"

# ------------------------------------------------------------------
# 1. Create directories
# ------------------------------------------------------------------
mkdir -p "$PI_DIR" "$EXT_DIR" 2>/dev/null || true

# ------------------------------------------------------------------
# 2. settings.json (exact copy from dotfiles — provider, model, thinking, packages)
# ------------------------------------------------------------------
if [ -f "$REPO_DIR/dotfiles/pi/agent/settings.json" ]; then
    cp "$REPO_DIR/dotfiles/pi/agent/settings.json" "$PI_DIR/settings.json"
    echo "  settings.json -> $PI_DIR/settings.json"
else
    echo "  WARNING: dotfiles/pi/agent/settings.json not found; skipping."
fi

# ------------------------------------------------------------------
# 3. trust.json (exact copy from dotfiles — trusts "/")
# ------------------------------------------------------------------
if [ -f "$REPO_DIR/dotfiles/pi/agent/trust.json" ]; then
    cp "$REPO_DIR/dotfiles/pi/agent/trust.json" "$PI_DIR/trust.json"
    echo "  trust.json -> $PI_DIR/trust.json"
else
    echo "  WARNING: dotfiles/pi/agent/trust.json not found; skipping."
fi

# ------------------------------------------------------------------
# 4. auth.json (template from dotfiles, keys filled from setup.keys.rs)
# ------------------------------------------------------------------
XAI_KEY="${XAI_API_KEY:-}"
DEEPSEEK_KEY="${DEEPSEEK_API_KEY:-}"

if [ -z "$DEEPSEEK_KEY" ]; then
    echo "  WARNING: DEEPSEEK_API_KEY not found in $KEYS_FILE."
    echo "           Creating auth.json with empty keys (user can fill them later)."
fi

cat > "$PI_DIR/auth.json" << AUTHJSON
{
  "xai": {
    "type": "api_key",
    "key": "$XAI_KEY"
  },
  "deepseek": {
    "type": "api_key",
    "key": "$DEEPSEEK_KEY"
  }
}
AUTHJSON
chmod 600 "$PI_DIR/auth.json" 2>/dev/null || true
echo "  auth.json -> $PI_DIR/auth.json  (DEEPSEEK_API_KEY from setup.keys.rs)"

# ------------------------------------------------------------------
# 5. Extensions (readonly-mode)
# ------------------------------------------------------------------
if cp "$REPO_DIR/dotfiles/pi/readonly-mode.ts" "$EXT_DIR/readonly-mode.ts" 2>/dev/null; then
    echo "  readonly-mode.ts -> $EXT_DIR/readonly-mode.ts"
    if su - "$TARGET_USER" -c "/usr/local/bin/pi install $EXT_DIR/readonly-mode.ts"; then
        echo "  readonly-mode extension registered for $TARGET_USER."
    else
        echo "  WARNING: pi install readonly-mode.ts failed for $TARGET_USER (non-fatal)."
    fi
fi

# ------------------------------------------------------------------
# 6. Chown everything to the target user
# ------------------------------------------------------------------
chown -R "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.pi" 2>/dev/null || true

echo ""
echo "SUCCESS: pi-coding-agent configured for $TARGET_USER."
echo "  Provider: deepseek  |  Model: deepseek-v4-pro  |  Thinking: high"
echo "  Keys source: $KEYS_FILE"
echo "  Config:      $PI_DIR/"
exit 0
