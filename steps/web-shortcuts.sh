#!/bin/bash
# steps/web-shortcuts.sh - BROWSER LAUNCHERS (w, w?, wk)
#
# w    : open a URL / shortcut in Chromium (normal profile)
# w?   : list the available shortcuts
# wk   : open a URL / shortcut in Chromium, private only, keeping NO URL
#        history (--incognito + throwaway --user-data-dir in tmpfs that is
#        deleted on exit; never hands the URL to a running instance)
#
# Idempotent: only copies files, never touches a running browser.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "BROWSER LAUNCHERS (w / w? / wk)"
echo "*****************************************************"

ok=0
mkdir -p /usr/local/bin

deploy() {  # $1 = source basename, $2 = installed name
    src="$REPO_DIR/dotfiles/chromium/$1"
    dst="$2"
    if [ ! -f "$src" ]; then
        echo "  WARNING: $src missing"
        ok=1
        return
    fi
    install -m 755 "$src" "$dst" 2>/dev/null || { cp "$src" "$dst" && chmod 755 "$dst"; }
    if [ -x "$dst" ]; then
        echo "  installed $dst"
    else
        echo "  ERROR: failed to install $dst"
        ok=1
    fi
}

deploy w   /usr/local/bin/w
deploy w_q '/usr/local/bin/w?'
deploy wk  /usr/local/bin/wk

# Sanity: make sure the scripts at least parse and behave without a browser
for b in /usr/local/bin/w /usr/local/bin/wk '/usr/local/bin/w?'; do
    [ -x "$b" ] || continue
    bash -n "$b" 2>/dev/null || sh -n "$b" 2>/dev/null || {
        echo "  ERROR: syntax error in $b"; ok=1;
    }
done

if [ $ok -eq 0 ]; then
    echo "SUCCESS: w (normal) / wk (private, no history) launchers installed."
    exit 0
else
    echo "ERROR: browser launcher setup had issues."
    exit 1
fi
