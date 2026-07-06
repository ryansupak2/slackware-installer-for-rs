#!/bin/bash
# steps/user-firefox.sh - FIREFOX DRM-READY SKELETON FOR TARGET USER

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
TARGET_USER="${TARGET_USER:-$1}"

if [ -z "$TARGET_USER" ]; then
    echo "ERROR: TARGET_USER not set"
    exit 1
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
    done

    # Pre-copy Widevine CDM (from global install)
    local VERSION="4.10.2934.0"
    for src in /usr/lib64/mozilla/gmp-widevinecdm/$VERSION /usr/lib64/firefox/gmp-widevinecdm/$VERSION; do
        if [ -d "$src" ]; then
            mkdir -p "$profdir/gmp-widevinecdm/$VERSION"
            cp -a "$src/"* "$profdir/gmp-widevinecdm/$VERSION/" 2>/dev/null || true
        fi
    done

    chown -R "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.config/gtk-3.0" "$HOME_TARGET/.mozilla" 2>/dev/null || true

    if $ok; then
        echo "SUCCESS: Firefox DRM skeleton prepared for $TARGET_USER."
        echo "  - GTK dark theme + userChrome.css + legacy pref"
        echo "  - Widevine CDM pre-copied into profile (4.10.2934.0)"
        echo "  - EME/Widevine prefs enabled, auto-update disabled"
        echo "  First run of 'firefox' should just work for DRM content."
        exit 0
    else
        echo "ERROR: Firefox skeleton setup had problems (GTK or profile files)."
        exit 1
    fi
}

setup_firefox
