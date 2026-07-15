#!/bin/bash
# steps/user-firefox.sh - FIREFOX DRM-READY SKELETON FOR TARGET USER

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
echo "FIREFOX (DRM-READY SKELETON) FOR $TARGET_USER"
echo "*****************************************************"

HOME_TARGET=$(eval echo ~$TARGET_USER)

setup_firefox() {
    local ok=true

    # GTK dark theme
    mkdir -p "$HOME_TARGET/.config/gtk-3.0"
    if [ -f "$REPO_DIR/dotfiles/gtk/settings.ini" ]; then
        cp "$REPO_DIR/dotfiles/gtk/settings.ini" "$HOME_TARGET/.config/gtk-3.0/settings.ini" 2>/dev/null || ok=false
        chmod 644 "$HOME_TARGET/.config/gtk-3.0/settings.ini" 2>/dev/null || true
    fi

    # Default profile skeleton
    local profdir="$HOME_TARGET/.mozilla/firefox/default"
    mkdir -p "$profdir/chrome"

    # userChrome.css for dark top bar
    if [ -f "$REPO_DIR/dotfiles/firefox/chrome/userChrome.css" ]; then
        cp "$REPO_DIR/dotfiles/firefox/chrome/userChrome.css" "$profdir/chrome/userChrome.css" 2>/dev/null || true
        chmod 644 "$profdir/chrome/userChrome.css" 2>/dev/null || true
    fi

    # Prefs
    local userjs="$profdir/user.js"
    local prefsjs="$profdir/prefs.js"
    touch "$userjs" "$prefsjs" 2>/dev/null || true

    for f in "$userjs" "$prefsjs"; do
        if ! grep -q 'toolkit.legacyUserProfileCustomizations.stylesheets' "$f" 2>/dev/null; then
            echo 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);' >> "$f"
        fi
        for p in media.gmp-widevinecdm.enabled media.gmp-widevinecdm.visible media.eme.enabled; do
            if ! grep -q "user_pref(\"$p\", true);" "$f" 2>/dev/null; then
                echo "user_pref(\"$p\", true);" >> "$f"
            fi
        done
        if ! grep -q 'media.gmp-manager.updateEnabled' "$f" 2>/dev/null; then
            echo 'user_pref("media.gmp-manager.updateEnabled", true);' >> "$f"
        fi

        # Disable session restore — never reopen old tabs on launch
        for p in browser.sessionstore.resume_from_crash browser.sessionstore.resume_session_once; do
            if ! grep -q "user_pref(\"$p\", false);" "$f" 2>/dev/null; then
                echo "user_pref(\"$p\", false);" >> "$f"
            fi
        done
        if ! grep -q 'browser.startup.page' "$f" 2>/dev/null; then
            echo 'user_pref("browser.startup.page", 0);' >> "$f"
        fi
        for p in browser.sessionstore.max_tabs_undo browser.sessionstore.max_windows_undo; do
            if ! grep -q "user_pref(\"$p\", 0);" "$f" 2>/dev/null; then
                echo "user_pref(\"$p\", 0);" >> "$f"
            fi
        done
    done

    chown -R "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.config/gtk-3.0" "$HOME_TARGET/.mozilla" 2>/dev/null || true

    if $ok; then
        echo "SUCCESS: Firefox DRM skeleton prepared for $TARGET_USER."
        echo "  - GTK dark theme + userChrome.css + legacy pref"
        echo "  - EME/Widevine prefs enabled, auto-update enabled"
        echo "  - Firefox will auto-download Widevine on first DRM site visit"
        exit 0
    else
        echo "ERROR: Firefox skeleton setup had problems (GTK or profile files)."
        exit 1
    fi
}

setup_firefox
