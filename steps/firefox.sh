#!/bin/bash
# steps/firefox.sh - FIREFOX WITH WIDEVINE DRM (Slackware edition)
# On Slackware (glibc), Firefox + Widevine work natively — no gcompat/patchelf needed.
# Firefox 140+ downloads Widevine automatically via the built-in GMP manager.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

# Tell the main runner that firefox was attempted (for the post-run message)
touch /tmp/firefox-ran.marker || true

echo "*****************************************************"
echo "FIREFOX WITH WIDEVINE DRM"
echo "*****************************************************"

ok=true

# -------------------------------------------------------------------
# 1. Upgrade Firefox to latest ESR (slackpkg install skips if present)
# -------------------------------------------------------------------
echo "Checking for Firefox upgrades from Slackware /extra..."
UPGRADE_NEEDED=$(slackpkg search firefox 2>/dev/null | grep 'upgrade' || true)
if [ -n "$UPGRADE_NEEDED" ]; then
    echo "Upgrade available: $UPGRADE_NEEDED"
    echo "Running slackpkg upgrade mozilla-firefox..."
    slackpkg -batch=on -default_answer=y upgrade mozilla-firefox 2>&1 | tee -a "$LOG_FILE"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        echo "WARNING: slackpkg upgrade firefox failed — trying install as fallback."
        if ! install_pkg "mozilla-firefox"; then
            echo "ERROR: mozilla-firefox not available from slackpkg /extra."
            ok=false
        fi
    fi
else
    echo "No upgrade available; ensuring firefox is installed..."
    if ! install_pkg "mozilla-firefox"; then
        echo "ERROR: mozilla-firefox not available from slackpkg /extra."
        ok=false
    fi
fi

# Show installed version
INSTALLED_VER=$(ls /var/log/packages/mozilla-firefox-* 2>/dev/null | head -1 | sed 's/.*mozilla-firefox-//;s/-x86_64.*//')
echo "Firefox version: ${INSTALLED_VER:-unknown}"

# -------------------------------------------------------------------
# 2. Firefox wrapper (dark theme + Widevine env vars)
# -------------------------------------------------------------------
if $ok; then
    echo "Creating the dark-chrome launcher with Widevine support..."

    cat > /usr/bin/firefox << 'WRAPPER'
#!/bin/sh
exec env \
    MOZ_DISABLE_GMP_SANDBOX=1 \
    MOZ_GMP_PATH=/usr/lib64/mozilla/gmp-widevinecdm:/usr/lib64/firefox/gmp-widevinecdm \
    GTK_THEME=Adwaita:dark \
    MOZ_GTK_TITLEBAR_DECORATION=client \
    /usr/lib64/firefox/firefox "$@"
WRAPPER
    chmod +x /usr/bin/firefox
    cp /usr/bin/firefox /usr/local/bin/firefox 2>/dev/null || true
    chmod +x /usr/local/bin/firefox 2>/dev/null || true

    ln -sf /usr/bin/firefox /usr/bin/browser 2>/dev/null || true
    ln -sf /usr/bin/firefox /usr/local/bin/browser 2>/dev/null || true

    if [ -L /usr/lib64/firefox/firefox-bin ]; then
        rm -f /usr/lib64/firefox/firefox-bin 2>/dev/null || true
        ln -sf /usr/bin/firefox /usr/lib64/firefox/firefox-bin 2>/dev/null || true
    fi

    hash -r 2>/dev/null || true
    echo "SUCCESS: /usr/bin/firefox is now the dark-chrome + Widevine wrapper."

    # Quick-launch wrappers
    cp "$REPO_DIR/dotfiles/firefox/w" /usr/local/bin/w
    chmod +x /usr/local/bin/w
    cp "$REPO_DIR/dotfiles/firefox/w_q" '/usr/local/bin/w?'
    chmod +x '/usr/local/bin/w?'
    echo "SUCCESS: /usr/local/bin/w and /usr/local/bin/w? installed."
    echo "         'w y' -> youtube.com, 'w g' -> google.com, 'w?' -> list shortcuts"
fi

# -------------------------------------------------------------------
# 3. Widevine CDM — let Firefox auto-download via GMP manager
#    Firefox 140+ handles this automatically when visiting a DRM site.
#    We pre-seed the prefs to enable auto-download and remove stale CDMs.
# -------------------------------------------------------------------
if $ok; then
    echo "Configuring Widevine DRM for automatic download..."

    # Remove any stale pre-provisioned CDM from old installs
    rm -rf /usr/lib64/firefox/gmp-widevinecdm 2>/dev/null || true
    rm -rf /usr/lib64/mozilla/gmp-widevinecdm 2>/dev/null || true

    echo "Widevine will be downloaded by Firefox on first DRM site visit."
    echo "(Set media.gmp-manager.updateEnabled=true prefs below.)"
fi

# -------------------------------------------------------------------
# 4. Deploy dark GTK theme + userChrome.css + Widevine prefs
# -------------------------------------------------------------------
if $ok; then
    echo "Installing dark Firefox chrome + Widevine auto-download prefs..."

    mkdir -p /etc/skel/.config/gtk-3.0 /root/.config/gtk-3.0
    cp "$REPO_DIR/dotfiles/gtk/settings.ini" /etc/skel/.config/gtk-3.0/settings.ini 2>/dev/null || true
    cp "$REPO_DIR/dotfiles/gtk/settings.ini" /root/.config/gtk-3.0/settings.ini 2>/dev/null || true

    for base in /root /etc/skel /home/*; do
        [ -d "$base" ] || continue
        for profdir in "$base/.mozilla/firefox/"*; do
            [ -d "$profdir" ] || continue
            if [ -f "$profdir/prefs.js" ] || [ -f "$profdir/user.js" ] || echo "$profdir" | grep -q 'default'; then
                mkdir -p "$profdir/chrome" 2>/dev/null || true
                cp "$REPO_DIR/dotfiles/firefox/chrome/userChrome.css" "$profdir/chrome/userChrome.css" 2>/dev/null || true
                touch "$profdir/user.js" "$profdir/prefs.js" 2>/dev/null || true

                # legacy customizations
                if ! grep -q 'toolkit.legacyUserProfileCustomizations.stylesheets' "$profdir/user.js" 2>/dev/null; then
                    echo 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);' >> "$profdir/user.js"
                fi
                if ! grep -q 'toolkit.legacyUserProfileCustomizations.stylesheets' "$profdir/prefs.js" 2>/dev/null; then
                    echo 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);' >> "$profdir/prefs.js"
                fi

                # Widevine prefs — now with auto-update ENABLED so Firefox downloads the right version
                for p in 'media.gmp-widevinecdm.enabled' 'media.gmp-widevinecdm.visible' 'media.eme.enabled'; do
                    if ! grep -q "user_pref(\"$p\", true);" "$profdir/prefs.js" 2>/dev/null; then
                        echo "user_pref(\"$p\", true);" >> "$profdir/prefs.js"
                    fi
                    if ! grep -q "user_pref(\"$p\", true);" "$profdir/user.js" 2>/dev/null; then
                        echo "user_pref(\"$p\", true);" >> "$profdir/user.js"
                    fi
                done

                # Auto-download Widevine (was false — now true so Firefox fetches it)
                echo 'user_pref("media.gmp-manager.updateEnabled", true);' >> "$profdir/prefs.js"
                echo 'user_pref("media.gmp-manager.updateEnabled", true);' >> "$profdir/user.js"
            fi
        done
    done
    echo "Dark chrome + Widevine auto-download prefs deployed."
fi

# -------------------------------------------------------------------
# 5. Cleanup
# -------------------------------------------------------------------
echo "Cleaning up any stale headless Firefox processes..."
pkill -f 'ff-drm-install-profile' 2>/dev/null || true
pkill -f '--headless.*--profile' 2>/dev/null || true
pkill -f 'firefox.*--headless' 2>/dev/null || true
sleep 1
pkill -9 -f 'ff-drm-install-profile' 2>/dev/null || true
pkill -9 -f '/usr/lib64/firefox/firefox' 2>/dev/null || true
rm -rf /tmp/ff-drm-install-profile 2>/dev/null || true

if $ok; then
    echo ""
    echo "SUCCESS: Firefox is ready with Widevine auto-download enabled."
    echo "Launch Firefox and visit a DRM site (YouTube, Netflix) —"
    echo "Firefox will download the latest Widevine CDM automatically."
    exit 0
else
    echo "ERROR: Firefox + DRM setup encountered failures."
    exit 1
fi
