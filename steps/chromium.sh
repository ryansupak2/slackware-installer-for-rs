#!/bin/bash
# steps/chromium.sh — locally built Chromium, Debian style:
#   * Widevine DRM possible (proprietary_codecs + enable_widevine + Chrome's CDM)
#   * URL bar and tab strip font sizes independently adjustable at runtime
#   * installed as /usr/lib/chromium/chromium + /usr/bin/chromium wrapper
#
# WHY THIS STEP EXISTS (do not "simplify" it back to the SBo package):
#   Slackware's only Chromium is ungoogled-chromium-bin, which is compiled
#   WITHOUT Widevine support. Measured on this box (steps/chrome.sh:7-13):
#       Chromium 154 -> requestMediaKeySystemAccess('com.widevine.alpha')
#                       rejects with NotSupportedError
#       Chrome   157 -> resolves (WIDEVINE_OK)
#   That is a compile-time property: no flag, pref or CDM placement can fix a
#   binary built with enable_widevine=false. So we build our own with the same
#   switches Debian uses, and supply the CDM the way Debian does — as a drop-in
#   copy taken from Google Chrome's .deb, never redistributed.
#
#   On top of that, the patch in patches/chromium/ decouples the URL bar font
#   size from the tab strip font size (stock Chromium: 14pt vs 12pt targets,
#   not separately configurable). That patch is the reason the build is ours.
#
#   Google Chrome (/usr/local/bin/chrome, steps/chrome.sh) stays the default
#   browser for w / wk / Mod+b and stays the DRM baseline. This build is for
#   "one browser, no Chrome, and I want to tune the UI text".
#
# USAGE
#   REPO_DIR=/root/Development/slackware-installer-for-rs bash steps/chromium.sh [cmd]
#
#     all         preflight + fetch + unpack + patch + gen + build + install + verify
#                 (idempotent; safe to re-run, resumes an interrupted build)
#     preflight   toolchain / library / disk / network checks only
#     fetch       download the pinned source tarball (~1.5 GB)
#     unpack      extract + prime the tree (no patches)
#     patch       apply patches/chromium/*.patch, verify they landed
#     gen         write out/Default/args.gn and run gn gen
#     build       ninja -C out/Default chrome          (HOURS on 6 cores)
#     install     copy to /usr/lib/chromium + wrapper + /etc/chromium
#     verify      --version, patch-in-binary check, Widevine EME probe
#     rebase      after a version bump: re-apply patches, report every .rej
#     status      what exists (tarball / source / patched / built / installed)
#     clean       delete the build workspace (needs CONFIRM=1)
#
# ENV
#   CHROMIUM_VERSION_OVERRIDE   build a different tag without editing the pin
#   CHROMIUM_BUILD_ROOT         workspace (default /var/cache/chromium-build)
#   CHROMIUM_OFFICIAL=1         is_official_build=true (Debian-like, much slower)
#   CHROMIUM_JOBS               ninja -j (default $(nproc), raise only with RAM)
#   CHROMIUM_SKIP_DEPCHECK=1    continue even when a library looks missing
#   BROWSER_REFRESH / CONFIRM   as documented in the subcommands
#
# Version updates: lib/chromium-version.sh (the pin + the checklist) and
# doc/chromium-build.md ("Bumping the version"). Read those before touching the
# patch files — the invariants there are what keeps the font feature alive.

REPO_DIR="${REPO_DIR:-/root/Development/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/${USER:-root}-chromium-$(date +%Y%m%d-%H%M%S).log}"

# shellcheck source=/dev/null
[ -f "$REPO_DIR/lib/common.sh" ] && . "$REPO_DIR/lib/common.sh"
# shellcheck source=/dev/null
[ -f "$REPO_DIR/lib/chromium-version.sh" ] && . "$REPO_DIR/lib/chromium-version.sh" \
    || { echo "ERROR: $REPO_DIR/lib/chromium-version.sh not found (set REPO_DIR)"; exit 1; }

: "${CHROMIUM_VERSION:=157.0.8103.38}"
[ -n "${CHROMIUM_VERSION_OVERRIDE:-}" ] && {
    CHROMIUM_VERSION="$CHROMIUM_VERSION_OVERRIDE"
    CHROMIUM_TARBALL_URL="https://commondatastorage.googleapis.com/chromium-browser-official/chromium-${CHROMIUM_VERSION}.tar.xz"
}

SRC="$CHROMIUM_BUILD_ROOT/src"
OUT="$SRC/out/Default"
TARBALL="$CHROMIUM_BUILD_ROOT/chromium-$CHROMIUM_VERSION.tar.xz"
TARBALL_SHA="$TARBALL.sha256"
PATCH_DIR="$REPO_DIR/patches/chromium"
JOBS="${CHROMIUM_JOBS:-$(nproc 2>/dev/null || echo 4)}"
INSTALL_MARKER="$CHROMIUM_INSTALL_DIR/VERSION"

ok=true
say()  { echo "$*"; }
warn() { echo "WARNING: $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

need_root() {
    [ "$(id -u)" = "0" ] || die "must run as root (writes /usr/lib/chromium, /etc/chromium)"
}

patch_fingerprint() {
    # Fingerprint of the patch set: changes invalidate the "already applied"
    # marker, so a rebased patch is never silently skipped.
    local sum=""
    local p
    for p in "$PATCH_DIR"/*.patch; do
        [ -f "$p" ] || continue
        sum="$sum$(sha256sum "$p" | cut -c1-16):"
    done
    echo "$sum"
}

src_version() {
    # chrome/VERSION holds MAJOR/MINOR/BUILD/PATCH lines.
    [ -f "$SRC/chrome/VERSION" ] || { echo ""; return; }
    local major minor build patch
    major=$(sed -n 's/^MAJOR=//p' "$SRC/chrome/VERSION")
    minor=$(sed -n 's/^MINOR=//p' "$SRC/chrome/VERSION")
    build=$(sed -n 's/^BUILD=//p' "$SRC/chrome/VERSION")
    patch=$(sed -n 's/^PATCH=//p' "$SRC/chrome/VERSION")
    echo "${major}.${minor}.${build}.${patch}"
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
find_gn() {
    # gn binary, in order: explicit override, system, previously built here,
    # else build gn from source.
    #
    # depot_tools' gn wrapper is deliberately NOT used: depot_tools refuses to
    # bootstrap as root ("Running depot tools as root is sad") and this box runs
    # everything as root. Building gn (gn.googlesource.com/gn, ~1 min) avoids
    # the whole issue and keeps the toolchain self-contained.
    if [ -n "${CHROMIUM_GN:-}" ] && [ -x "$CHROMIUM_GN" ]; then
        echo "$CHROMIUM_GN"; return 0
    fi
    if command -v gn >/dev/null 2>&1; then
        command -v gn; return 0
    fi
    local gnsrc="$CHROMIUM_BUILD_ROOT/gn"
    local gnbin="$gnsrc/out/gn"
    if [ -x "$gnbin" ]; then
        echo "$gnbin"; return 0
    fi
    if [ ! -d "$gnsrc" ]; then
        # stdout is the gn path: all progress goes to stderr.
        echo "  fetching gn (gn.googlesource.com/gn)" >&2
        git clone --depth 1 https://gn.googlesource.com/gn "$gnsrc" >&2 || return 1
    fi
    # --no-last-commit-position: gen.py otherwise runs `git describe --match
    # initial-commit`, which cannot work in a shallow clone (no tags) and fails
    # with "No names found, cannot describe anything".
    # CXX: without it, gen.py insists on the hermetic (CIPD) clang toolchain and
    # dies with "cipd executable not found in PATH". With CXX set it uses that
    # compiler, which is all gn needs.
    local gn_cxx
    gn_cxx="${CXX:-$(command -v clang++ || command -v g++)}"
    [ -n "$gn_cxx" ] || { echo "  no C++ compiler for gn" >&2; return 1; }
    ( cd "$gnsrc" && CXX="$gn_cxx" python3 build/gen.py --no-last-commit-position ) >&2 \
        || { echo "  gn gen.py failed" >&2; return 1; }
    ( cd "$gnsrc" && ninja -C out gn ) >&2 || { echo "  gn build failed" >&2; return 1; }
    [ -x "$gnbin" ] || { echo "  gn binary missing after build" >&2; return 1; }
    echo "$gnbin"
}

cmd_preflight() {
    say "PREFLIGHT"
    local missing_pkgs="" missing_tools="" m pkg

    for tool in python3 pkg-config ninja git curl xz sha256sum; do
        if command -v "$tool" >/dev/null 2>&1; then
            say "  ok   tool: $tool"
        else
            say "  MISS tool: $tool"
            missing_tools="$missing_tools $tool"
        fi
    done
    for tool in bison flex gperf; do
        command -v "$tool" >/dev/null 2>&1 && say "  ok   tool: $tool" \
            || { say "  MISS tool: $tool"; missing_tools="$missing_tools $tool"; }
    done

    # pkg-config module -> Slackware package providing it
    for pair in "gtk+-3.0:gtk+3" "nss:nss" "alsa:alsa-lib" "libdrm:libdrm" \
                "xkbcommon:libxkbcommon" "cups:cups" "dbus-1:dbus" \
                "expat:expat" "fontconfig:fontconfig" "freetype2:freetype" \
                "libpulse:pulseaudio" "x11:libX11" "xcomposite:libXcomposite" \
                "xdamage:libXdamage" "xfixes:libXfixes" "xrandr:libXrandr" \
                "xtst:libXtst" "xi:libXi"; do
        m="${pair%%:*}"; pkg="${pair#*:}"
        if pkg-config --exists "$m" 2>/dev/null; then
            say "  ok   lib: $m"
        else
            say "  MISS lib: $m   (slackpkg install $pkg)"
            missing_pkgs="$missing_pkgs $pkg"
        fi
    done

    local probe_dir="$CHROMIUM_BUILD_ROOT"
    [ -d "$probe_dir" ] || probe_dir="/"
    say "  disk: $(df -Pk "$probe_dir" | awk 'NR==2 {printf "%.0f GB free on %s (%s)", $4/1048576, $6, $1}') — a build needs ~50 GB peak"

    if ! GN=$(find_gn); then
        warn "gn not available: install depot_tools' gn, or export CHROMIUM_GN=/path/to/gn"
        ok=false
    else
        say "  ok   gn: $GN ($("$GN" --version 2>/dev/null))"
    fi

    if [ -n "$missing_tools$missing_pkgs" ]; then
        say ""
        say "Missing before a Chromium build will work:"
        [ -n "$missing_tools" ] && say "  tools: $missing_tools"
        [ -n "$missing_pkgs" ] && say "  slackpkg install$missing_pkgs"
        if [ "${CHROMIUM_SKIP_DEPCHECK:-0}" != "1" ]; then
            ok=false
        else
            warn "CHROMIUM_SKIP_DEPCHECK=1 — continuing anyway"
        fi
    fi

    # Network + tarball availability (cheap HEAD, no download).
    if [ -f "$TARBALL" ]; then
        say "  ok   tarball cached: $TARBALL ($(du -h "$TARBALL" | cut -f1))"
    else
        local code
        code=$(curl -sSI -o /dev/null -w '%{http_code}' "$CHROMIUM_TARBALL_URL" 2>/dev/null)
        if [ "$code" = "200" ]; then
            say "  ok   tarball reachable: chromium-$CHROMIUM_VERSION.tar.xz (~1.5 GB download)"
        else
            warn "tarball not reachable (HTTP $code): $CHROMIUM_TARBALL_URL"
            ok=false
        fi
    fi

    $ok || die "preflight failed (fix the above, or CHROMIUM_SKIP_DEPCHECK=1)"
    say "preflight: OK"
}

# ---------------------------------------------------------------------------
# fetch / unpack
# ---------------------------------------------------------------------------
cmd_fetch() {
    mkdir -p "$CHROMIUM_BUILD_ROOT"
    if [ -f "$TARBALL" ] && [ -f "$TARBALL_SHA" ]; then
        say "Verifying cached tarball..."
        if ( cd "$CHROMIUM_BUILD_ROOT" && sha256sum -c "$(basename "$TARBALL_SHA")" >/dev/null 2>&1 ); then
            say "  cached tarball OK (sha256 verified): $TARBALL"
            return 0
        fi
        warn "cached tarball fails its checksum — re-downloading"
        rm -f "$TARBALL" "$TARBALL_SHA"
    fi
    say "Downloading chromium-$CHROMIUM_VERSION.tar.xz (~1.5 GB, resumable)..."
    curl -fL --retry 3 -C - -o "$TARBALL.part" "$CHROMIUM_TARBALL_URL" || {
        rm -f "$TARBALL.part"; die "download failed: $CHROMIUM_TARBALL_URL"; }
    mv "$TARBALL.part" "$TARBALL"
    ( cd "$CHROMIUM_BUILD_ROOT" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL_SHA")" )
    say "  sha256 recorded: $TARBALL_SHA"
}

cmd_unpack() {
    [ -f "$TARBALL" ] || die "no tarball — run: $0 fetch"
    local have
    have=$(src_version)
    if [ "$have" = "$CHROMIUM_VERSION" ] && [ -f "$SRC/BUILD.gn" ]; then
        say "Source already unpacked: $SRC (Chromium $have)"
        return 0
    fi
    if [ -e "$SRC" ]; then
        say "Removing stale source tree ($(du -sh "$SRC" | cut -f1))..."
        rm -rf "$SRC" || die "cannot remove $SRC"
    fi
    mkdir -p "$SRC"
    say "Extracting $(du -h "$TARBALL" | cut -f1) tarball (10+ minutes, lots of files)..."
    tar -xJf "$TARBALL" -C "$SRC" --strip-components=1 || die "extraction failed"
    have=$(src_version)
    [ "$have" = "$CHROMIUM_VERSION" ] \
        || die "unpacked tree reports version '$have', expected '$CHROMIUM_VERSION'"
    say "  unpacked: $SRC (Chromium $have, $(du -sh "$SRC" | cut -f1))"

    # Chromium wants a LASTCHANGE file; tarballs lack one.
    if [ ! -f "$SRC/build/util/LASTCHANGE" ]; then
        say "  priming build/util/LASTCHANGE (tarballs ship without git metadata)"
        ( cd "$SRC" && python3 build/util/lastchange.py -o build/util/LASTCHANGE >/dev/null 2>&1 ) \
            || warn "could not prime LASTCHANGE — gn gen may complain (see doc/chromium-build.md)"
    fi
}

ensure_toolchain() {
    # Debian/Arch style: build with the DISTRIBUTION clang (clang_base_path="/usr"
    # in lib/chromium-gn-args.gn) instead of fetching Chromium's pinned clang.
    # Reasons: the pinned clang comes from CIPD via tools/clang/scripts/
    # update.py, which drags in depot_tools and refuses to run as root; and a
    # 1-2 GB download per version is pointless when the system clang is newer
    # than the one Chromium pins.
    #
    # If the system clang is ever too old, Chromium will say so at gn gen time
    # ("clang too old" / compile failures on new C++ features). That is the
    # moment to fetch the pinned one by hand — see doc/chromium-build.md.
    local clang_bin lld_bin ver
    clang_bin=$(command -v clang) || { warn "no clang in PATH"; return 1; }
    ver=$("$clang_bin" --version 2>/dev/null | sed -n 's/.*clang version \([0-9][0-9]*\).*/\1/p' | head -1)
    say "  clang: $("$clang_bin" --version 2>/dev/null | head -1)"
    if [ -n "$ver" ] && [ "$ver" -lt 18 ]; then
        warn "clang $ver is older than Chromium 157 expects (>= 18). Either upgrade"
        warn "llvm, or fetch the pinned clang: python3 tools/clang/scripts/update.py"
        warn "(needs CIPD; depot_tools refuses to run as root, so expect to fix that)"
        return 1
    fi
    if lld_bin=$(command -v ld.lld); then
        say "  lld:   $lld_bin"
    else
        warn "no ld.lld — the build will use GNU ld (slower, use_lld=false)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# patch
# ---------------------------------------------------------------------------
cmd_patch() {
    [ -f "$SRC/BUILD.gn" ] || die "no source tree — run: $0 unpack"
    local fp marker
    fp=$(patch_fingerprint)
    marker="$SRC/.installer-patches"

    if [ ! -d "$PATCH_DIR" ] || ! ls "$PATCH_DIR"/*.patch >/dev/null 2>&1; then
        die "no patches in $PATCH_DIR (the font feature lives there — do not delete it)"
    fi

    if [ -f "$marker" ] && [ "$(cat "$marker")" = "$fp" ]; then
        say "Patches already applied (fingerprint ${fp%:})"
        verify_patched_tree || die "tree is marked patched but the changes are not there"
        return 0
    fi

    # A different fingerprint on an already-patched tree: undo first.
    if [ -f "$marker" ]; then
        say "Patch set changed — reversing the previous set first"
        reverse_patches
    fi

    say "Applying patches from $PATCH_DIR:"
    local p
    for p in "$PATCH_DIR"/*.patch; do
        say "  - $(basename "$p")"
        if ( cd "$SRC" && git apply -p1 "$p" ); then
            say "    applied with git apply"
        else
            warn "    git apply failed, trying patch -p1 --fuzz=3"
            if ( cd "$SRC" && patch -p1 --forward --fuzz=3 < "$p" >/dev/null ); then
                say "    applied with patch(1) (fuzzy — check for .orig drift)"
            else
                ( cd "$SRC" && patch -p1 --forward --fuzz=3 < "$p" 2>&1 | head -20 )
                die "patch $(basename "$p") does NOT apply to Chromium $CHROMIUM_VERSION.
       Chromium moved the code this patch touches. Rebase it:
         1. read the .rej/.orig files under $SRC
         2. update $PATCH_DIR/$(basename "$p") by hand against the new source
         3. keep the '// BEGIN/END chrome-ui-font-parser' markers (tests depend on them)
         4. bash tests/chromium-ui-font-parse.sh
       Full procedure: doc/chromium-build.md"
            fi
        fi
    done

    verify_patched_tree || die "patches applied but the changes are not where they should be"
    echo "$fp" > "$marker"
    say "Patched tree verified."
}

verify_patched_tree() {
    # Cheap structural checks: if any of these fail, the font feature is gone
    # even though the build may still succeed. Never skip this.
    local miss=0
    grep -q "CONTEXT_TAB_TITLE" "$SRC/ui/views/style/typography.h" 2>/dev/null || { warn "  missing CONTEXT_TAB_TITLE in ui/views/style/typography.h"; miss=1; }
    grep -q "chrome_ui_font" "$SRC/chrome/browser/ui/views/chrome_typography.h" 2>/dev/null || { warn "  missing chrome_ui_font declarations"; miss=1; }
    grep -q "BEGIN chrome-ui-font-parser" "$SRC/chrome/browser/ui/views/chrome_typography.cc" 2>/dev/null || { warn "  missing parser block in chrome_typography.cc"; miss=1; }
    grep -q "chrome_ui_font::OmniboxDelta" "$SRC/chrome/browser/ui/views/chrome_typography_provider.cc" 2>/dev/null || { warn "  provider does not consult OmniboxDelta()"; miss=1; }
    grep -q "SetTextContext(views::style::CONTEXT_TAB_TITLE)" "$SRC/chrome/browser/ui/views/tabs/tab/tab_title.cc" 2>/dev/null || { warn "  TabTitle does not use CONTEXT_TAB_TITLE"; miss=1; }
    return $miss
}

# ---------------------------------------------------------------------------
# gen / build
# ---------------------------------------------------------------------------
cmd_gen() {
    [ -f "$SRC/BUILD.gn" ] || die "no source tree — run: $0 unpack"
    GN=$(find_gn) || die "gn not found (preflight tried: system gn, gn built from source, CHROMIUM_GN)"
    ensure_toolchain || warn "toolchain checks reported problems; gn gen will tell you the rest"

    mkdir -p "$OUT"
    local official="false" lld="true"
    [ "${CHROMIUM_OFFICIAL:-0}" = "1" ] && official="true"
    # use_lld is decided here, not in the args file, so a machine without lld
    # still builds (GNU ld, slower link).
    command -v ld.lld >/dev/null 2>&1 || lld="false"
    {
        echo "# generated by steps/chromium.sh from lib/chromium-gn-args.gn — do not edit by hand"
        cat "$REPO_DIR/lib/chromium-gn-args.gn"
        echo ""
        echo "is_official_build = $official"
        echo "use_lld = $lld"
    } > "$OUT/args.gn" || die "cannot write $OUT/args.gn"

    say "Running gn gen (is_official_build=$official, use_lld=$lld)..."
    ( cd "$SRC" && "$GN" gen out/Default ) || die "gn gen failed.
   Common causes on Slackware:
     * clang too old / missing      -> run: $0 gen (see the toolchain lines above)
     * missing LASTCHANGE           -> python3 build/util/lastchange.py -o build/util/LASTCHANGE
     * missing system library       -> run: $0 preflight
     * unknown gn arg              -> gn args --list out/Default | grep <name>
   See doc/chromium-build.md."
    say "gn gen: OK ($OUT/args.gn)"
}

cmd_build() {
    [ -f "$OUT/build.ninja" ] || die "not generated — run: $0 gen"
    if [ -x "$OUT/chrome" ]; then
        local got
        got=$("$OUT/chrome" --version 2>/dev/null | head -1)
        say "Already built: $got (delete $OUT to force a rebuild)"
        return 0
    fi
    say "Building Chromium $CHROMIUM_VERSION with -j$JOBS — this takes hours."
    say "Progress is ninja output; an interrupted build resumes where it stopped."
    ( cd "$SRC" && ninja -C out/Default -j"$JOBS" chrome ) || die "build failed (ninja output above)"
    [ -x "$OUT/chrome" ] || die "ninja finished but $OUT/chrome is missing"
    say "Built: $("$OUT/chrome" --version 2>/dev/null | head -1)"
}

# ---------------------------------------------------------------------------
# install (Debian layout)
# ---------------------------------------------------------------------------
installed_state() {
    [ -f "$INSTALL_MARKER" ] || { echo ""; return; }
    cat "$INSTALL_MARKER"
}

desired_marker() {
    echo "$CHROMIUM_VERSION+patches$(patch_fingerprint | cut -c1-16)"
}

cmd_install() {
    need_root
    [ -x "$OUT/chrome" ] || die "no built binary — run: $0 build"
    local want have
    want=$(desired_marker)
    have=$(installed_state)
    if [ "$have" = "$want" ] && [ -x "$CHROMIUM_INSTALL_DIR/chromium" ]; then
        say "Already installed: $(cat "$INSTALL_MARKER")"
        return 0
    fi

    say "Installing to $CHROMIUM_INSTALL_DIR (Debian layout)..."
    mkdir -p "$CHROMIUM_INSTALL_DIR/locales" || die "cannot create $CHROMIUM_INSTALL_DIR"

    install -m 755 "$OUT/chrome" "$CHROMIUM_INSTALL_DIR/chromium" || die "cannot install binary"

    # Resources the browser and its renderers load at runtime. Missing ones are
    # skipped with a note: this list drifts between versions, and a browser
    # that runs without an optional file is better than a hard failure.
    local f base
    for f in resources.pak chrome_100_percent.pak chrome_200_percent.pak \
             icudtl.dat v8_context_snapshot.bin snapshot_blob.bin \
             chrome_crashpad_handler chrome_sandbox \
             libEGL.so libGLESv2.so libvk_swiftshader.so libvulkan.so.1 \
             vk_swiftshader_icd.json; do
        if [ -e "$OUT/$f" ]; then
            cp -a "$OUT/$f" "$CHROMIUM_INSTALL_DIR/" || warn "  copy failed: $f"
        else
            say "  skipped (not produced by this build): $f"
        fi
    done
    if [ -d "$OUT/locales" ]; then
        cp -a "$OUT/locales/." "$CHROMIUM_INSTALL_DIR/locales/" || warn "  locales copy failed"
    fi
    [ -d "$OUT/MEIPreload" ] && cp -a "$OUT/MEIPreload" "$CHROMIUM_INSTALL_DIR/" 2>/dev/null

    # Widevine CDM, Debian-style: supplied by the user/packager, never built.
    # Take Chrome's copy — same CDM Chrome itself verified with the EME probe in
    # steps/chrome.sh, and licensing forbids redistributing it.
    if [ -f /opt/google/chrome/WidevineCdm/manifest.json ]; then
        rm -rf "$CHROMIUM_INSTALL_DIR/WidevineCdm"
        cp -a /opt/google/chrome/WidevineCdm "$CHROMIUM_INSTALL_DIR/" \
            && say "  WidevineCdm <- /opt/google/chrome ($(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' /opt/google/chrome/WidevineCdm/manifest.json | head -1))"
    else
        warn "no /opt/google/chrome/WidevineCdm — DRM will NOT work in this build."
        warn "install Google Chrome first (steps/chrome.sh) then re-run: $0 install"
    fi

    # Wrapper + settings (canonical sources under dotfiles/chromium/).
    install -m 755 "$REPO_DIR/dotfiles/chromium/chromium-wrapper" "$CHROMIUM_WRAPPER_PATH" \
        || die "cannot install $CHROMIUM_WRAPPER_PATH"
    mkdir -p "$CHROMIUM_ETC_DIR/chromium.d"
    if [ -f "$CHROMIUM_UI_FONT_CONF" ]; then
        say "  keeping existing $CHROMIUM_UI_FONT_CONF (tuned values survive re-installs)"
    else
        install -m 644 "$REPO_DIR/dotfiles/chromium/ui-font.conf" "$CHROMIUM_UI_FONT_CONF"
        say "  wrote $CHROMIUM_UI_FONT_CONF (stock deltas 0/0)"
    fi
    install -m 644 "$REPO_DIR/dotfiles/chromium/chromium.d-00-defaults.conf" \
        "$CHROMIUM_ETC_DIR/chromium.d/00-defaults.conf"

    install -m 755 "$REPO_DIR/scripts/chromium-ui-font.sh" /usr/local/bin/chromium-ui-font \
        || { cp "$REPO_DIR/scripts/chromium-ui-font.sh" /usr/local/bin/chromium-ui-font \
             && chmod 755 /usr/local/bin/chromium-ui-font; }
    say "  /usr/local/bin/chromium-ui-font installed (usage: chromium-ui-font show)"

    echo "$want" > "$INSTALL_MARKER"
    say "Installed: $want"
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
probe_drm() {   # $1 = browser command to probe
    local p out
    p=$(mktemp -d /tmp/eme.XXXXXX) || return 1
    cat > "$p/probe.html" << 'HTMLEOF'
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
    out=$(timeout 120 $1 --headless=new --disable-gpu --user-data-dir="$p/ud" \
            --virtual-time-budget=8000 --dump-dom "file://$p/probe.html" 2>/dev/null \
          | grep -o 'EME_RESULT: [A-Z_]*[A-Za-z ]*' | head -1)
    rm -rf "$p"
    echo "$out"
}

cmd_verify() {
    need_root
    $ok || warn "continuing despite earlier warnings"
    [ -x "$CHROMIUM_INSTALL_DIR/chromium" ] || die "not installed — run: $0 install"

    say "1. binary"
    local ver
    ver=$("$CHROMIUM_INSTALL_DIR/chromium" --version 2>/dev/null | head -1)
    [ -n "$ver" ] || die "binary does not run"
    say "   $ver"
    case "$ver" in
        *"$CHROMIUM_VERSION"*) say "   version matches the pin" ;;
        *) warn "   version does not match the pin ($CHROMIUM_VERSION)" ;;
    esac

    say "2. UI font patch present in the binary"
    # The parser's config path and key names only exist if the patch compiled in.
    if strings "$CHROMIUM_INSTALL_DIR/chromium" 2>/dev/null | grep -q "/etc/chromium/ui-font.conf"; then
        say "   OK: reads /etc/chromium/ui-font.conf"
    else
        warn "   config path NOT found in the binary — the font patch is missing!"
        ok=false
    fi
    for key in omnibox_delta tab_delta; do
        if strings "$CHROMIUM_INSTALL_DIR/chromium" 2>/dev/null | grep -qx "$key"; then
            say "   OK: honours $key"
        else
            warn "   key '$key' NOT found in the binary — the font patch is missing!"
            ok=false
        fi
    done

    say "3. Widevine (headless EME probe)"
    local eme
    eme=$(probe_drm "$CHROMIUM_WRAPPER_PATH")
    say "   probe: ${eme:-no result}"
    case "$eme" in
        *WIDEVINE_OK*) say "   OK: com.widevine.alpha available (Netflix/YouTube DRM will play)" ;;
        *) warn "   DRM NOT available in this build — check the CDM copy and re-run install"
           ok=false ;;
    esac

    say "4. current UI font settings"
    if [ -x /usr/local/bin/chromium-ui-font ]; then
        /usr/local/bin/chromium-ui-font show
    else
        warn "   chromium-ui-font not installed"
    fi

    $ok || die "verification failed (see warnings above)"
    say "verify: OK — launch with: chromium"
}

# ---------------------------------------------------------------------------
# rebase / status / clean
# ---------------------------------------------------------------------------
reverse_patches() {
    # Best effort: undo whatever of the previous set is still applied, so a
    # rebase starts from (near) pristine source.
    local p
    for p in $(ls -r "$PATCH_DIR"/*.patch 2>/dev/null); do
        ( cd "$SRC" && git apply -R -p1 "$p" >/dev/null 2>&1 ) \
            || warn "  could not cleanly reverse $(basename "$p")"
    done
}

cmd_rebase() {
    [ -f "$SRC/BUILD.gn" ] || die "no source tree — run: $0 fetch unpack"
    if [ -f "$SRC/.installer-patches" ]; then
        say "Tree already carries the previous patch set — reversing it first"
        reverse_patches
        rm -f "$SRC/.installer-patches"
    fi
    say "Rebasing patches onto Chromium $(src_version):"
    local p rej
    for p in "$PATCH_DIR"/*.patch; do
        say "  - $(basename "$p")"
        if ( cd "$SRC" && git apply -p1 --check "$p" >/dev/null 2>&1 ); then
            ( cd "$SRC" && git apply -p1 "$p" ) && say "    applies cleanly" && continue
        fi
        warn "    does NOT apply cleanly — writing reject files for you"
        ( cd "$SRC" && patch -p1 --forward --fuzz=3 --no-backup-if-mismatch < "$p" >/dev/null 2>&1 )
        rej=$(cd "$SRC" && find . -name '*.rej' | head -20)
        say "    rejects:"
        echo "$rej" | sed 's/^/      /'
        say "    Fix the patch by hand against the new source, keeping:"
        say "      * the CONTEXT_TAB_TITLE enum entry in ui/views/style/typography.h"
        say "      * the chrome_ui_font declarations in chrome_typography.h"
        say "      * the BEGIN/END chrome-ui-font-parser markers in chrome_typography.cc"
        say "      * the delta switch in chrome_typography_provider.cc"
        say "      * SetTextContext(...CONTEXT_TAB_TITLE) in tabs/tab/tab_title.cc"
        say "    then: bash tests/chromium-ui-font-parse.sh && $0 patch"
        ok=false
    done
    # Reject files are deliberately left on disk: they are what you edit the
    # patch against. They live under $SRC and vanish with the next unpack.
    $ok || die "rebase incomplete — see rejects above and doc/chromium-build.md"
    say "rebase: OK"
}

cmd_status() {
    say "Chromium build status (pin: $CHROMIUM_VERSION)"
    say "  workspace:    $CHROMIUM_BUILD_ROOT"
    [ -f "$TARBALL" ] && say "  tarball:      yes ($(du -h "$TARBALL" | cut -f1))" || say "  tarball:      no"
    local have
    have=$(src_version)
    [ -n "$have" ] && say "  source:       $SRC (Chromium $have)" || say "  source:       no"
    [ -f "$SRC/.installer-patches" ] && say "  patches:      applied ($(cat "$SRC/.installer-patches" | cut -c1-16))" || say "  patches:      not applied"
    [ -x "$OUT/chrome" ] && say "  built:        yes ($("$OUT/chrome" --version 2>/dev/null | head -1))" || say "  built:        no"
    local have_i
    have_i=$(installed_state)
    [ -n "$have_i" ] && say "  installed:    $have_i" || say "  installed:    no"
    if [ -f "$CHROMIUM_UI_FONT_CONF" ]; then
        say "  ui-font.conf: $(grep -v '^#' "$CHROMIUM_UI_FONT_CONF" | grep . | tr '\n' ' ')"
    else
        say "  ui-font.conf: none (stock sizing)"
    fi
    return 0
}

cmd_clean() {
    if [ "${CONFIRM:-0}" != "1" ]; then
        say "Would delete $CHROMIUM_BUILD_ROOT ($(du -sh "$CHROMIUM_BUILD_ROOT" 2>/dev/null | cut -f1 || echo 'absent'))"
        say "Re-run with CONFIRM=1 to do it. The installed browser is NOT touched."
        return 0
    fi
    rm -rf "$CHROMIUM_BUILD_ROOT"
    say "Removed $CHROMIUM_BUILD_ROOT. Installed browser untouched."
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
cmd_all() {
    cmd_preflight
    cmd_fetch
    cmd_unpack
    cmd_patch
    cmd_gen
    cmd_build
    cmd_install
    cmd_verify
}

case "${1:-all}" in
    all)       cmd_all ;;
    preflight) cmd_preflight ;;
    fetch)     cmd_fetch ;;
    unpack)    cmd_unpack ;;
    patch)     cmd_patch ;;
    gen)       cmd_gen ;;
    build)     cmd_build ;;
    install)   cmd_install ;;
    verify)    cmd_verify ;;
    rebase)    cmd_rebase ;;
    status)    cmd_status ;;
    clean)     cmd_clean ;;
    -h|--help|help) sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown command '$1' (try: $0 help)" ;;
esac
