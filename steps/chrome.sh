#!/bin/bash
# steps/chrome.sh - GOOGLE CHROME + WIDEVINE DRM (replaces Firefox)
#
# The browser on this machine is Google Chrome. Context for the shape of this
# step, so nobody "simplifies" it into a broken DRM setup later:
#
#   * Slackware ships no chromium package, and SBo only offers
#     ungoogled-chromium-bin, which states plainly that "Widevine DRM is not
#     included" — its build cannot load the CDM at all. Measured on this box:
#         Chromium 154  -> navigator.requestMediaKeySystemAccess('com.widevine.alpha')
#                          rejects with NotSupportedError
#         Chrome   157  -> resolves (WIDEVINE_OK)
#     So DRM (Netflix, YouTube movies) requires Google Chrome.
#   * Consequently Chrome comes from Google's official .deb, which is also the
#     only distributable source of libwidevinecdm.so. The .deb is cached in
#     /var/cache/browser and repacked to /opt/google/chrome (same layout the
#     upstream .deb uses), no apt/dpkg involved.
#   * DRM is VERIFIED, not assumed: a headless EME probe must resolve
#     com.widevine.alpha or the step fails.
#   * Chromium is optional: BROWSER_CHROMIUM=1 sbopkg-installs
#     ungoogled-chromium-bin as a DRM-free secondary browser.
#
# Idempotent: cached .deb is reused, the extraction/verification is skipped
# when the install is already good.

REPO_DIR="${REPO_DIR:-/root/Development/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "GOOGLE CHROME + WIDEVINE DRM"
echo "*****************************************************"

# Tell the main runner this step ran (drives the post-run DRM notes)
touch /tmp/browser-ran.marker || true

ok=true
CACHE_DIR="/var/cache/browser"
DEB="$CACHE_DIR/google-chrome-stable_current_amd64.deb"
CHROME_DIR="/opt/google/chrome"
DEB_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"

# Is a Chromium binary actually present/requested? Determines whether the
# Widevine copy and the chromium package are wanted at all.
need_chromium_cdm() {
    [ "${BROWSER_CHROMIUM:-0}" = "1" ] && return 0
    [ -x /usr/bin/ungoogled-chromium ] && return 0
    [ -x /usr/bin/chromium ] && return 0
    return 1
}

# -------------------------------------------------------------------
# 1. Fetch the official .deb (cached; refresh with BROWSER_REFRESH=1)
# -------------------------------------------------------------------
mkdir -p "$CACHE_DIR"
if [ -f "$DEB" ] && [ "${BROWSER_REFRESH:-0}" != "1" ]; then
    echo "Using cached .deb: $DEB ($(du -h "$DEB" | cut -f1))"
    echo "  (BROWSER_REFRESH=1 re-downloads a newer Chrome)"
else
    echo "Downloading Google Chrome .deb (~145 MB)..."
    if curl -fL --retry 3 -o "$DEB.part" "$DEB_URL"; then
        mv "$DEB.part" "$DEB"
    else
        echo "ERROR: download failed."
        rm -f "$DEB.part"
        ok=false
    fi
fi

# -------------------------------------------------------------------
# 2. Unpack into /opt/google/chrome
# -------------------------------------------------------------------
if $ok && [ ! -x "$CHROME_DIR/chrome" ]; then
    echo "Unpacking Chrome to $CHROME_DIR..."
    WORK=$(mktemp -d /tmp/chrome-deb.XXXXXX) || WORK=""
    if [ -n "$WORK" ] && (cd "$WORK" && ar x "$DEB" 2>/dev/null); then
        DATA=$(ls "$WORK"/data.tar.* 2>/dev/null | head -1)
        if [ -n "$DATA" ] && tar -xf "$DATA" -C "$WORK" ./opt/google/chrome 2>/dev/null; then
            mkdir -p "$CHROME_DIR"
            cp -a "$WORK/opt/google/chrome/." "$CHROME_DIR/"
            chmod 755 "$CHROME_DIR/chrome" 2>/dev/null || true
            echo "  unpacked"
        else
            echo "ERROR: could not unpack data.tar payload"
            ok=false
        fi
        # Desktop entry + icons, if the .deb ships them
        if tar -xf "$DATA" -C "$WORK" ./usr/share/applications ./usr/share/icons 2>/dev/null; then
            mkdir -p /usr/share/applications /usr/share/icons
            cp -a "$WORK/usr/share/applications/." /usr/share/applications/ 2>/dev/null || true
            cp -a "$WORK/usr/share/icons/." /usr/share/icons/ 2>/dev/null || true
        fi
    else
        echo "ERROR: could not read the .deb with ar"
        ok=false
    fi
    [ -n "$WORK" ] && rm -rf "$WORK"
else
    [ -x "$CHROME_DIR/chrome" ] && echo "Chrome already unpacked: $("$CHROME_DIR/chrome" --version 2>/dev/null | tail -1)"
fi

# System-level entry points (what other tools expect to find)
if [ -x "$CHROME_DIR/chrome" ]; then
    ln -sf "$CHROME_DIR/chrome" /usr/bin/google-chrome-stable 2>/dev/null || true
    ln -sf "$CHROME_DIR/chrome" /usr/bin/google-chrome 2>/dev/null || true
    echo "Chrome: $("$CHROME_DIR/chrome" --version 2>/dev/null | tail -1)"
else
    echo "ERROR: $CHROME_DIR/chrome missing"
    ok=false
fi

# -------------------------------------------------------------------
# 3. /usr/local/bin/chrome — single entry point for w / wk / Mod+b
# -------------------------------------------------------------------
if [ -x "$CHROME_DIR/chrome" ]; then
    # UI scale. This panel is 2560x1600 over an ~11.3" diagonal (~226 DPI) but
    # X reports 96 DPI, so Chrome draws its UI (URL bar, tabs, menus) at the
    # default ~12px. 1.2 puts it at ~14.4px: comfortably larger than stock
    # without dwarfing the page. (2.25 was tried first and was ~2x too big.)
    # Override per-launch with CHROME_UI_SCALE=<factor>.
    UI_SCALE="${CHROME_UI_SCALE:-1.2}"
    cat > /usr/local/bin/chrome << WRAPPER
#!/bin/sh
# chrome — entry point for w / wk / Mod+b. Google Chrome, because the Chromium
# builds available to this installer cannot load the Widevine CDM.
#
# --force-device-scale-factor enlarges the UI text (URL bar, tabs, menus).
# 1.2 => ~14.4px, i.e. clearly bigger than stock but not oversized.
# Override per launch: CHROME_UI_SCALE=1.3 w y
exec $CHROME_DIR/chrome --force-device-scale-factor=\${CHROME_UI_SCALE:-$UI_SCALE} "\$@"
WRAPPER
    chmod 755 /usr/local/bin/chrome
    ln -sf /usr/local/bin/chrome /usr/bin/browser 2>/dev/null || true
    ln -sf /usr/local/bin/chrome /usr/local/bin/browser 2>/dev/null || true
    echo "  /usr/local/bin/chrome -> $CHROME_DIR/chrome"
fi

# 4. Widevine CDM for a Chromium build — only when Chromium is actually here.
#    Copying it for a browser that is not installed just leaves 42 MB of orphan
#    files behind (Chrome carries its own CDM).
# -------------------------------------------------------------------
WV_SO="/usr/lib64/chromium/WidevineCdm/_platform_specific/linux_x64/libwidevinecdm.so"
if need_chromium_cdm; then
    if [ ! -f "$WV_SO" ] && [ -d "$CHROME_DIR/WidevineCdm" ]; then
        mkdir -p /usr/lib64/chromium
        cp -a "$CHROME_DIR/WidevineCdm" /usr/lib64/chromium/ 2>/dev/null || true
        echo "  WidevineCdm -> /usr/lib64/chromium/WidevineCdm"
    fi
fi

# -------------------------------------------------------------------
# 5. DRM verification (EME probe) — must resolve com.widevine.alpha
# -------------------------------------------------------------------
probe_drm() {   # $1 = browser binary
    P=$(mktemp -d /tmp/eme.XXXXXX) || return 1
    cat > "$P/probe.html" << 'HTMLEOF'
<html><body><div id="out">pending</div><script>
(async () => {
  const cfg = [{ initDataTypes: ['cenc'],
    videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.42E01E"' }] }];
  try {
    await navigator.requestMediaKeySystemAccess('com.widevine.alpha', cfg);
    document.getElementById('out').textContent = 'EME_RESULT: WIDEVINE_OK';
  } catch (e) {
    document.getElementById('out').textContent = 'EME_RESULT: WIDEVINE_FAIL ' + e.name;
  }
})();
</script></body></html>
HTMLEOF
    OUT=$(timeout 60 "$1" --headless=new --no-sandbox --disable-gpu \
            --user-data-dir="$P/ud" --virtual-time-budget=8000 \
            --dump-dom "file://$P/probe.html" 2>/dev/null \
          | grep -o 'EME_RESULT: [A-Z_]*[A-Za-z ]*' | head -1)
    rm -rf "$P"
    echo "$OUT"
}

DRM_OK=false
if [ -x "$CHROME_DIR/chrome" ]; then
    echo "Verifying Widevine DRM (EME probe)..."
    EME_OUT=$(probe_drm "$CHROME_DIR/chrome")
    echo "  probe: ${EME_OUT:-no result}"
    case "$EME_OUT" in *WIDEVINE_OK*) DRM_OK=true ;; esac
fi
if $DRM_OK; then
    echo "  DRM OK: com.widevine.alpha available (Netflix/YouTube DRM will play)"
else
    echo "  ERROR: Widevine not available — DRM video will NOT play"
    ok=false
fi

# -------------------------------------------------------------------
# 6. Remove Firefox
# -------------------------------------------------------------------
echo "Removing Firefox..."
if pkg_installed "mozilla-firefox" 2>/dev/null; then
    slackpkg -batch=on -default_answer=y remove mozilla-firefox 2>&1 | tail -2
    echo "  firefox package removed"
fi
for f in /usr/local/bin/firefox /usr/bin/firefox; do
    [ -e "$f" ] && rm -f "$f" && echo "  removed $f"
done
# Firefox profile data is dead weight once the program is gone (bookmarks,
# logins, history), so drop the whole profile tree — not just the prefs files
# the old step used to seed.
for d in /root/.mozilla /home/*/.mozilla /etc/skel/.mozilla; do
    [ -e "$d" ] || continue
    rm -rf "$d" && echo "  removed $d"
done

# GTK font. Chrome's menus/dialogs and every other GTK app read this; the old
# 9pt was unreadable on this ~226 DPI panel (terminal is 28px).
GTK_SRC="$REPO_DIR/dotfiles/gtk/settings.ini"
if [ -f "$GTK_SRC" ]; then
    for base in /root /etc/skel; do
        mkdir -p "$base/.config/gtk-3.0"
        cp "$GTK_SRC" "$base/.config/gtk-3.0/settings.ini" 2>/dev/null \
            && echo "  gtk settings -> $base/.config/gtk-3.0/settings.ini"
    done
fi
# -------------------------------------------------------------------
# 7. Optional DRM-free secondary browser
# -------------------------------------------------------------------
if [ "${BROWSER_CHROMIUM:-0}" = "1" ]; then
    echo "Installing Chromium (DRM-free secondary browser)..."
    if install_sbo "ungoogled-chromium-bin"; then
        # now present: give it the CDM too (harmless when unusable)
        if [ -d "$CHROME_DIR/WidevineCdm" ] && [ ! -f "$WV_SO" ]; then
            mkdir -p /usr/lib64/chromium
            cp -a "$CHROME_DIR/WidevineCdm" /usr/lib64/chromium/ 2>/dev/null || true
            echo "  WidevineCdm -> /usr/lib64/chromium/WidevineCdm"
        fi
    else
        echo "  WARNING: chromium install failed (Chrome still works)"
    fi
else
    # Not wanted: remove it and its orphan files, so the machine only carries
    # what it actually runs (~777 MB package + ~42 MB of CDM copies).
    echo "Removing unused Chromium..."
    if pkg_installed "ungoogled-chromium-bin" 2>/dev/null; then
        slackpkg -batch=on -default_answer=y remove ungoogled-chromium-bin 2>&1 | tail -1
    fi
    for d in /opt/ungoogled-chromium-bin /usr/lib64/chromium /usr/lib/chromium; do
        [ -e "$d" ] && rm -rf "$d" && echo "  removed $d"
    done
    echo "Skipping Chromium (BROWSER_CHROMIUM=1 to add it as a DRM-free extra)."
fi

# -------------------------------------------------------------------
# 8. Launchers (w / w? / wk)
# -------------------------------------------------------------------
bash "$REPO_DIR/steps/web-shortcuts.sh" || ok=false

if $ok; then
    echo "SUCCESS: Google Chrome installed, Widevine DRM verified, Firefox removed."
    exit 0
else
    echo "ERROR: browser setup incomplete (see messages above)."
    exit 1
fi
