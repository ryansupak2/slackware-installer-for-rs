#!/bin/bash
# steps/firefox.sh - FIREFOX WITH WIDEVINE DRM (Slackware edition)
# On Slackware (glibc), Firefox + Widevine work natively — no gcompat/patchelf needed.

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

echo "Installing firefox from Slackware /extra..."
# mozilla-firefox is in the official /extra directory, accessible via slackpkg
if ! install_pkg "mozilla-firefox"; then
    echo "ERROR: mozilla-firefox not available from slackpkg /extra."
    ok=false
fi

if $ok; then
    echo "Creating the dark-chrome launcher and making it the only firefox in the system..."

    # Write a wrapper that forces dark GTK theme + client-side decorations (no musl workarounds needed)
    cat > /usr/bin/firefox << 'WRAPPER'
#!/bin/sh
exec env \
    GTK_THEME=Adwaita:dark \
    MOZ_GTK_TITLEBAR_DECORATION=client \
    /usr/lib64/firefox/firefox "$@"
WRAPPER
    chmod +x /usr/bin/firefox

    cp /usr/bin/firefox /usr/local/bin/firefox 2>/dev/null || true
    chmod +x /usr/local/bin/firefox 2>/dev/null || true

    # Browser aliases also use our wrapper
    ln -sf /usr/bin/firefox /usr/bin/browser 2>/dev/null || true
    ln -sf /usr/bin/firefox /usr/local/bin/browser 2>/dev/null || true

    # Remove any stale firefox-bin symlink
    if [ -L /usr/lib64/firefox/firefox-bin ]; then
        rm -f /usr/lib64/firefox/firefox-bin 2>/dev/null || true
        ln -sf /usr/bin/firefox /usr/lib64/firefox/firefox-bin 2>/dev/null || true
    fi

    hash -r 2>/dev/null || true

    echo "SUCCESS: /usr/bin/firefox is now the dark-chrome wrapper."

    # Install Firefox quick-launch wrappers (shortcut resolution for the 'w' alias)
    cp "$REPO_DIR/dotfiles/firefox/w" /usr/local/bin/w
    chmod +x /usr/local/bin/w
    cp "$REPO_DIR/dotfiles/firefox/w_q" '/usr/local/bin/w?'
    chmod +x '/usr/local/bin/w?'

    echo "SUCCESS: /usr/local/bin/w and /usr/local/bin/w? installed."
    echo "         'w y' -> youtube.com, 'w g' -> google.com, 'w?' -> list shortcuts"
fi

if $ok; then
    echo "Installing Widevine CDM..."
    WIDEVINE_URL="https://edgedl.me.gvt1.com/edgedl/release2/chrome_component/accssjtqfpf5qicscrptql4jyyxa_4.10.2934.0/oimompecagnajdejgnnjijobebaeigek_4.10.2934.0_linux_ph722a3wl2goebkpserszm6bde.crx3"
    CRX="/tmp/widevinecdm.crx3"
    WORK="/tmp/wvcdm-work"
    VERSION="4.10.2934.0"

    rm -rf "$CRX" "$WORK" 2>/dev/null || true

    if curl -fsSL -o "$CRX" "$WIDEVINE_URL" >> "$LOG_FILE" 2>&1; then
        echo "Downloaded Widevine CRX."
        HEADER_SIZE=$(dd if="$CRX" bs=1 skip=8 count=4 2>/dev/null | od -An -tu4 | tr -d ' \n' || echo 0)
        if [ -z "$HEADER_SIZE" ] || [ "$HEADER_SIZE" -le 0 ]; then
            HEADER_SIZE=1050
        fi
        ZIP_OFFSET=$((12 + HEADER_SIZE))
        mkdir -p "$WORK"
        if dd if="$CRX" of="$WORK/widevine.zip" bs=1 skip="$ZIP_OFFSET" 2>/dev/null; then
            if unzip -o "$WORK/widevine.zip" -d "$WORK/extracted" >> "$LOG_FILE" 2>&1; then
                CDM_SO_SRC=$(find "$WORK/extracted" -name 'libwidevinecdm.so' 2>/dev/null | head -1 || true)
                if [ -f "$CDM_SO_SRC" ]; then
                    echo "Found libwidevinecdm.so."

                    # Slackware: Firefox libs are in /usr/lib64/firefox/
                    TARGET_GMP="/usr/lib64/firefox/gmp-widevinecdm/$VERSION"
                    mkdir -p "$TARGET_GMP"
                    cp -a "$CDM_SO_SRC" "$TARGET_GMP/"
                    cp -a "$WORK/extracted/manifest.json" "$TARGET_GMP/" 2>/dev/null || true
                    echo "Widevine CDM installed to $TARGET_GMP"

                    # Also install to /usr/lib64/mozilla/ for compatibility
                    TARGET_MOZ="/usr/lib64/mozilla/gmp-widevinecdm/$VERSION"
                    mkdir -p "$TARGET_MOZ"
                    cp -a "$CDM_SO_SRC" "$TARGET_MOZ/"
                    cp -a "$WORK/extracted/manifest.json" "$TARGET_MOZ/" 2>/dev/null || true
                else
                    echo "ERROR: libwidevinecdm.so not found in extracted CRX."
                    ok=false
                fi
            else
                echo "ERROR: unzip of Widevine payload failed."
                ok=false
            fi
        else
            echo "ERROR: failed to carve zip payload from CRX."
            ok=false
        fi
    else
        echo "ERROR: failed to download Widevine CDM."
        ok=false
    fi
    rm -rf "$CRX" "$WORK" 2>/dev/null || true
fi

# Deploy dark GTK theme + userChrome.css + prefs
if $ok; then
    echo "Installing dark Firefox chrome support..."

    # GTK dark theme for root + skeleton
    mkdir -p /etc/skel/.config/gtk-3.0 /root/.config/gtk-3.0
    cp "$REPO_DIR/dotfiles/gtk/settings.ini" /etc/skel/.config/gtk-3.0/settings.ini 2>/dev/null || true
    cp "$REPO_DIR/dotfiles/gtk/settings.ini" /root/.config/gtk-3.0/settings.ini 2>/dev/null || true

    # userChrome.css + Widevine prefs for all profiles
    for base in /root /etc/skel /home/*; do
        [ -d "$base" ] || continue
        for profdir in "$base/.mozilla/firefox/"*; do
            [ -d "$profdir" ] || continue
            if [ -f "$profdir/prefs.js" ] || [ -f "$profdir/user.js" ] || echo "$profdir" | grep -q 'default'; then
                mkdir -p "$profdir/chrome" 2>/dev/null || true
                cp "$REPO_DIR/dotfiles/firefox/chrome/userChrome.css" "$profdir/chrome/userChrome.css" 2>/dev/null || true
                touch "$profdir/user.js" "$profdir/prefs.js" 2>/dev/null || true
                if ! grep -q 'toolkit.legacyUserProfileCustomizations.stylesheets' "$profdir/user.js" 2>/dev/null; then
                    echo 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);' >> "$profdir/user.js"
                fi
                if ! grep -q 'toolkit.legacyUserProfileCustomizations.stylesheets' "$profdir/prefs.js" 2>/dev/null; then
                    echo 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);' >> "$profdir/prefs.js"
                fi
                # Widevine prefs
                for p in 'media.gmp-widevinecdm.enabled' 'media.gmp-widevinecdm.visible' 'media.eme.enabled'; do
                    if ! grep -q "user_pref(\"$p\", true);" "$profdir/prefs.js" 2>/dev/null; then
                        echo "user_pref(\"$p\", true);" >> "$profdir/prefs.js"
                    fi
                    if ! grep -q "user_pref(\"$p\", true);" "$profdir/user.js" 2>/dev/null; then
                        echo "user_pref(\"$p\", true);" >> "$profdir/user.js"
                    fi
                done
                echo 'user_pref("media.gmp-manager.updateEnabled", false);' >> "$profdir/prefs.js"
                echo 'user_pref("media.gmp-manager.updateEnabled", false);' >> "$profdir/user.js"
            fi
        done
    done
    echo "Dark chrome + Widevine prefs deployed."
fi

# Cleanup stale headless Firefox processes
echo "Cleaning up any temporary headless Firefox processes..."
pkill -f 'ff-drm-install-profile' 2>/dev/null || true
pkill -f '--headless.*--profile' 2>/dev/null || true
pkill -f 'firefox.*--headless' 2>/dev/null || true
sleep 1
pkill -9 -f 'ff-drm-install-profile' 2>/dev/null || true
pkill -9 -f '/usr/lib64/firefox/firefox' 2>/dev/null || true
rm -rf /tmp/ff-drm-install-profile 2>/dev/null || true

if $ok; then
    echo "SUCCESS: Firefox with pre-provisioned Widevine DRM is ready."
    exit 0
else
    echo "ERROR: Firefox + DRM setup encountered failures."
    exit 1
fi
