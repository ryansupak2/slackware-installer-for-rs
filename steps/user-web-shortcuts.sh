#!/bin/bash
# steps/user-web-shortcuts.sh - FIREFOX URL SHORTCUTS FOR TARGET USER

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

HOME_TARGET=$(eval echo ~$TARGET_USER)
SHORTCUT_DIR="$HOME_TARGET/.web"
SHORTCUT_FILE="$SHORTCUT_DIR/shortcuts"

mkdir -p "$SHORTCUT_DIR" 2>/dev/null

# The installed browser is Chromium/Chrome (see AGENTS.md); the shortcut list
# lives under dotfiles/chromium. Keep a firefox/ fallback for older trees.
SHORTCUTS_SRC="$REPO_DIR/dotfiles/chromium/shortcuts.default"
[ -f "$SHORTCUTS_SRC" ] || SHORTCUTS_SRC="$REPO_DIR/dotfiles/firefox/shortcuts.default"
if [ ! -f "$SHORTCUTS_SRC" ]; then
    echo "ERROR: no shortcuts.default found under dotfiles/chromium or dotfiles/firefox"
    exit 1
fi

if [ -f "$SHORTCUT_FILE" ]; then
    cp "$SHORTCUTS_SRC" "$SHORTCUT_FILE"
    echo "Overwritten $SHORTCUT_FILE"
else
    cp "$SHORTCUTS_SRC" "$SHORTCUT_FILE"
    echo "Created $SHORTCUT_FILE"
fi

chown "$TARGET_USER:$TARGET_USER" "$SHORTCUT_DIR" "$SHORTCUT_FILE" 2>/dev/null || true


echo "SUCCESS: Firefox URL shortcuts configured for $TARGET_USER."
echo "  Edit: $SHORTCUT_FILE"
echo "  Type shortcuts with 'w' (e.g., 'w y' → youtube.com): y g gr gm f x slsk"
exit 0
