#!/bin/bash
# steps/user-surf-shortcuts.sh - FIREFOX URL SHORTCUTS FOR TARGET USER

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
TARGET_USER="${TARGET_USER:-$1}"

if [ -z "$TARGET_USER" ]; then
    echo "ERROR: TARGET_USER not set"
    exit 1
fi

echo "FIREFOX URL SHORTCUTS FOR $TARGET_USER"

HOME_TARGET=$(eval echo ~$TARGET_USER)
SHORTCUT_DIR="$HOME_TARGET/.surf"
SHORTCUT_FILE="$SHORTCUT_DIR/shortcuts"

mkdir -p "$SHORTCUT_DIR" 2>/dev/null

if [ -f "$SHORTCUT_FILE" ] && [ -t 0 ]; then
    read -p "Overwrite $SHORTCUT_FILE? (y/n): " choice
    case "$choice" in
        y|Y)
            cp "$REPO_DIR/dotfiles/firefox/shortcuts.default" "$SHORTCUT_FILE"
            echo "Overwritten $SHORTCUT_FILE"
            ;;
        *)
            echo "Skipped $SHORTCUT_FILE (safety: no overwrite)"
            ;;
    esac
else
    cp "$REPO_DIR/dotfiles/firefox/shortcuts.default" "$SHORTCUT_FILE"
    echo "Created $SHORTCUT_FILE"
fi

chown "$TARGET_USER:$TARGET_USER" "$SHORTCUT_DIR" "$SHORTCUT_FILE" 2>/dev/null || true

echo "SUCCESS: Firefox URL shortcuts configured for $TARGET_USER."
echo "  Edit: $SHORTCUT_FILE"
echo "  Type shortcuts with 'w' (e.g., 'w y' → youtube.com): y g gr gm f x slsk"
exit 0
