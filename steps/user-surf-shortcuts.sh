#!/bin/bash
# steps/user-surf-shortcuts.sh - FIREFOX URL SHORTCUTS FOR TARGET USER

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
TARGET_USER="${TARGET_USER:-$1}"

if [ -z "$TARGET_USER" ]; then
    echo "ERROR: TARGET_USER not set"
    exit 1
fi

LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "FIREFOX URL SHORTCUTS FOR $TARGET_USER"
echo "*****************************************************"

echo "FIREFOX URL SHORTCUTS FOR $TARGET_USER"

HOME_TARGET=$(eval echo ~$TARGET_USER)
SHORTCUT_DIR="$HOME_TARGET/.surf"
SHORTCUT_FILE="$SHORTCUT_DIR/shortcuts"

mkdir -p "$SHORTCUT_DIR" 2>/dev/null

if [ -f "$SHORTCUT_FILE" ]; then
    cp "$REPO_DIR/dotfiles/firefox/shortcuts.default" "$SHORTCUT_FILE"
    echo "Overwritten $SHORTCUT_FILE"
else
    cp "$REPO_DIR/dotfiles/firefox/shortcuts.default" "$SHORTCUT_FILE"
    echo "Created $SHORTCUT_FILE"
fi

chown "$TARGET_USER:$TARGET_USER" "$SHORTCUT_DIR" "$SHORTCUT_FILE" 2>/dev/null || true

ok=true

if ! cp "$REPO_DIR/dotfiles/firefox/shortcuts.default" "$SHORTCUT_FILE" 2>/dev/null; then
    ok=false
fi

chown "$TARGET_USER:$TARGET_USER" "$SHORTCUT_DIR" "$SHORTCUT_FILE" 2>/dev/null || true

if $ok; then
    echo "SUCCESS: Firefox URL shortcuts configured for $TARGET_USER."
    echo "  Edit: $SHORTCUT_FILE"
    echo "  Type shortcuts with 'w' (e.g., 'w y' → youtube.com): y g gr gm f x slsk"
    exit 0
else
    echo "ERROR: Firefox URL shortcuts setup failed for $TARGET_USER."
    exit 1
fi
