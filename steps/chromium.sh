#!/bin/bash
# steps/chromium.sh - CHROMIUM (+ WIDEVINE DRM), replaces Firefox
#
# Why this shape:
#   * Slackware 15.0/16.0 ship no chromium package (verified: no PACKAGE NAME
#     match in the official tree), so Chromium comes from SBo:
#     network/ungoogled-chromium-bin (a prebuilt portable release).
#   * That build states plainly that "Widevine DRM is not included", and the
#     DRM-free binary cannot decrypt Netflix/YouTube DRM content. The Widevine
#     CDM itself is only distributed inside Google Chrome, so this step pulls
#     the official Chrome .deb purely as the CDM source, extracts
#     WidevineCdm/_platform_specific/linux_x64/libwidevinecdm.so and installs it
#     where Chromium probes for it.
#   * DRM is then VERIFIED, not assumed: a headless EME probe asks Chromium for
#     com.widevine.alpha. If the CDM cannot be loaded by this Chromium build,
#     the step falls back to the Google Chrome binary from the same .deb (which
#     bundles the CDM and is known to work with Netflix), and says so.
#   * Firefox is removed: package, wrappers, symlinks and dotfiles.
#
# Idempotent: re-running only fills in what is missing.

REPO_DIR="${REPO_DIR:-/root/Development/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "CHROMIUM + WIDEVINE DRM"
echo "*****************************************************"

# Tell the main runner this step ran (drives the post-run DRM notes)
touch /tmp/browser-ran.marker || true

ok=true
CHROME_DEB_DIR="/var/cache/browser"
CHROME_DEB="$CHROME_DEB_DIR/google-chrome-stable_current_amd64.deb"
WIDEVINE_PLATFORMS="/usr/lib64/chromium/WidevineCdm/_platform_specific/linux_x64"
CHROME_DIR="/opt/google/chrome"

# -------------------------------------------------------------------
# 1. Chromium package
# -------------------------------------------------------------------
echo "Installing Chromium..."
if pkg_installed "chromium" 2>/dev/null; then
    echo "  official chromium package already installed"
elif pkg_installed "ungoogled-chromium-bin" 2>/dev/null; then
    echo "  ungoogled-chromium-bin already installed"
elif install_pkg "chromium"; then
    echo "  official chromium package installed"
elif install_sbo "ungoogled-chromium-bin"; then
    echo "  ungoogled-chromium-bin installed"
else
    echo "ERROR: no Chromium package could be installed (chromium / ungoogled-chromium-bin)."
    ok=false
fi

# Locate the real binary
CHROMIUM_BIN=""
for cand in /usr/bin/chromium /usr/bin/ungoogled-chromium /usr/bin/chromium-browser; do
    [ -x "$cand" ] && { CHROMIUM_BIN="$cand"; break; }
done
[ -n "$CHROMIUM_BIN" ] && echo "  chromium binary: $CHROMIUM_BIN"

# -------------------------------------------------------------------
# 2. Widevine CDM (from the official Chrome .deb — the only distributor)
# -------------------------------------------------------------------
echo "Fetching Widevine CDM..."
mkdir -p "$CHROME_DEB_DIR"

if [ -x "$CHROME_DIR/chrome" ] && [ -f "$CHROME_DIR/WidevineCdm/manifest.json" ]; then
    echo "  existing Chrome install already provides the CDM"
fi

if [ ! -f "$CHROME_DEB" ]; then
    echo "  downloading Google Chrome .deb (CDM source, ~145 MB, one time)..."
    if ! curl -fL --retry 3 -o "$CHROME_DEB.part" \
            https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; then
        echo "ERROR: could not download the Chrome .deb (needed for Widevine)."
        rm -f "$CHROME_DEB.part"
        ok=false
    else
        mv "$CHROME_DEB.part" "$CHROME_DEB"
    fi
else
    echo "  using cached $CHROME_DEB"
fi

if [ -f "$CHROME_DEB" ] && [ ! -f "$WIDEVINE_PLATFORMS/libwidevinecdm.so" ]; then
    echo "  extracting WidevineCdm from the .deb..."
    WORK=$(mktemp -d /tmp/wv.XXXXXX) || WORK=""
    if [ -n "$WORK" ] && (cd "$WORK" && ar x "$CHROME_DEB" 2>/dev/null); then
        DATAFILE=$(ls "$WORK"/data.tar.* 2>/dev/null | head -1)
        if [ -n "$DATAFILE" ] && tar -xf "$DATAFILE" -C "$WORK" ./opt/google/chrome/WidevineCdm 2>/dev/null; then
            # Keep the full Chrome tree too: it is the fallback when Chromium
            # cannot load the CDM, and it is where the CDM was designed to run.
            mkdir -p "$CHROME_DIR"
            if [ ! -x "$CHROME_DIR/chrome" ]; then
                tar -xf "$DATAFILE" -C "$WORK" ./opt/google/chrome 2>/dev/null || true
                cp -a "$WORK/opt/google/chrome/." "$CHROME_DIR/" 2>/dev/null || true
            fi
            # Chromium probes these locations for the CDM. Create them even
            # when Chromium is not installed yet, otherwise a later chromium
            # install silently has no DRM.
            for dest in /usr/lib64/chromium /usr/lib/chromium; do
                mkdir -p "$dest"
                cp -a "$WORK/opt/google/chrome/WidevineCdm" "$dest/" 2>/dev/null || true
                echo "  WidevineCdm -> $dest/WidevineCdm"
            done
            if [ -d /opt/ungoogled-chromium-bin ]; then
                cp -a "$WORK/opt/google/chrome/WidevineCdm" /opt/ungoogled-chromium-bin/ 2>/dev/null || true
                echo "  WidevineCdm -> /opt/ungoogled-chromium-bin/WidevineCdm"
            fi
        else
            echo "  WARNING: could not unpack the .deb payload"
        fi
    fi
    [ -n "$WORK" ] && rm -rf "$WORK"
fi

if [ -f "$WIDEVINE_PLATFORMS/libwidevinecdm.so" ]; then
    echo "  CDM present: $WIDEVINE_PLATFORMS/libwidevinecdm.so ($(du -h "$WIDEVINE_PLATFORMS/libwidevinecdm.so" | cut -f1))"
else
    echo "  WARNING: Widevine CDM not found after extraction"
fi

# -------------------------------------------------------------------
# 3. /usr/local/bin/chrome — single entry point for w / wk
# -------------------------------------------------------------------
echo "Installing /usr/local/bin/chrome launcher..."
if [ -n "$CHROMIUM_BIN" ]; then
    TARGET_BIN="$CHROMIUM_BIN"
elif [ -x "$CHROME_DIR/chrome" ]; then
    TARGET_BIN="$CHROME_DIR/chrome"
else
    TARGET_BIN=""
    ok=false
fi

if [ -n "$TARGET_BIN" ]; then
    cat > /usr/local/bin/chrome << WRAPPER
#!/bin/sh
# chrome — entry point for w/wk. Points at whatever Chromium-family browser
# this machine ended up with (see steps/chromium.sh).
exec $TARGET_BIN "\$@"
WRAPPER
    chmod 755 /usr/local/bin/chrome
    echo "  /usr/local/bin/chrome -> $TARGET_BIN"
fi

# -------------------------------------------------------------------
# 4. DRM verification (EME probe) — the part that actually matters
# -------------------------------------------------------------------
echo "Verifying Widevine DRM (EME probe)..."
DRM_OK=false
if [ -n "$TARGET_BIN" ]; then
    PROBE=$(mktemp -d /tmp/eme.XXXXXX)
    cat > "$PROBE/probe.html" << 'HTMLEOF'
<html><body><div id="out">pending</div><script>
(async () => {
  const cfg = [{
    initDataTypes: ['cenc'],
    videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.42E01E"' }]
  }];
  try {
    await navigator.requestMediaKeySystemAccess('com.widevine.alpha', cfg);
    document.getElementById('out').textContent = 'EME_RESULT: WIDEVINE_OK';
  } catch (e) {
    document.getElementById('out').textContent = 'EME_RESULT: WIDEVINE_FAIL ' + e.name;
  }
})();
</script></body></html>
HTMLEOF
    EME_OUT=$(timeout 60 "$TARGET_BIN" --headless=new --no-sandbox --disable-gpu \
                --user-data-dir="$PROBE/ud" --virtual-time-budget=8000 \
                --dump-dom "file://$PROBE/probe.html" 2>/dev/null | grep -o 'EME_RESULT: [A-Z_]*[A-Za-z ]*' | head -1)
    rm -rf "$PROBE"
    echo "  probe: ${EME_OUT:-no result}"
    case "$EME_OUT" in
        *WIDEVINE_OK*) DRM_OK=true ;;
    esac
fi

if ! $DRM_OK && [ -x "$CHROME_DIR/chrome" ]; then
    echo "  this Chromium build cannot load the CDM — switching the launcher to Google Chrome"
    write_chrome_wrapper() {
        cat > /usr/local/bin/chrome << WRAPPER
#!/bin/sh
# chrome — entry point for w/wk. Falls back to Google Chrome because the
# Chromium build on this machine cannot load the Widevine CDM (no DRM).
exec $CHROME_DIR/chrome "\$@"
WRAPPER
        chmod 755 /usr/local/bin/chrome
    }
    write_chrome_wrapper
    # Desktop integration for the fallback
    ln -sf "$CHROME_DIR/chrome" /usr/bin/google-chrome-stable 2>/dev/null || true
    ln -sf "$CHROME_DIR/chrome" /usr/bin/google-chrome 2>/dev/null || true
    TARGET_BIN="$CHROME_DIR/chrome"

    PROBE=$(mktemp -d /tmp/eme.XXXXXX)
    cat > "$PROBE/probe.html" << 'HTMLEOF'
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
    EME_OUT=$(timeout 60 "$TARGET_BIN" --headless=new --no-sandbox --disable-gpu \
                --user-data-dir="$PROBE/ud" --virtual-time-budget=8000 \
                --dump-dom "file://$PROBE/probe.html" 2>/dev/null | grep -o 'EME_RESULT: [A-Z_]*[A-Za-z ]*' | head -1)
    rm -rf "$PROBE"
    echo "  probe (Chrome): ${EME_OUT:-no result}"
    case "$EME_OUT" in
        *WIDEVINE_OK*) DRM_OK=true ;;
    esac
fi

if $DRM_OK; then
    echo "  DRM OK: com.widevine.alpha is available (Netflix/YouTube will play)."
else
    echo "  WARNING: Widevine not available — DRM video will not play."
    ok=false
fi

# -------------------------------------------------------------------
# 5. Remove Firefox
# -------------------------------------------------------------------
echo "Removing Firefox..."
if pkg_installed "mozilla-firefox" 2>/dev/null; then
    slackpkg -batch=on -default_answer=y remove mozilla-firefox 2>&1 | tail -2
fi
# Wrappers/symlinks installed by the old steps/firefox.sh
for f in /usr/local/bin/firefox /usr/bin/firefox; do
    [ -e "$f" ] && rm -f "$f" && echo "  removed $f"
done
# 'browser' should now point at Chromium
ln -sf /usr/local/bin/chrome /usr/bin/browser 2>/dev/null || true
ln -sf /usr/local/bin/chrome /usr/local/bin/browser 2>/dev/null || true
# Old Firefox profile prefs seeded by steps/firefox.sh
for profdir in /root/.mozilla/firefox/*/ /etc/skel/.mozilla/firefox/*/; do
    [ -d "$profdir" ] || continue
    rm -f "$profdir/user.js" "$profdir/chrome/userChrome.css" 2>/dev/null || true
done

# -------------------------------------------------------------------
# 6. Launchers (w / w? / wk)
# -------------------------------------------------------------------
bash "$REPO_DIR/steps/web-shortcuts.sh" || ok=false

if $ok; then
    echo "SUCCESS: Chromium installed, Widevine DRM verified, Firefox removed."
    exit 0
else
    echo "ERROR: browser setup incomplete (see messages above)."
    exit 1
fi
