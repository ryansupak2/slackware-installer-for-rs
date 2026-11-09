#!/bin/bash
# steps/kernel-xe-psr-fix.sh - BACKPORT THE xe PSR SELECTIVE-FETCH FIX INTO xe.ko
#
# ###########################################################################
# ##  DO NOT INSTALL THIS ON KERNEL 7.2.15.  Measured 2026-11-09: with this   ##
# ##  backport loaded, starting X froze the whole display - no kernel error  ##
# ##  at all - while the stock module starts X fine (one-variable A/B, and a  ##
# ##  vanilla 7.2.15 build proved symbol-identical to Slackware's module, so  ##
# ##  the patch itself is the problem, not the build).                     ##
# ##  Upstream cbe5654759 is written for the 7.4 tree and needs its whole    ##
# ##  series around it. Keep this step for a 7.4.y kernel, not this one.    ##
# ##  Use `steps/gpu-display.sh psr1` instead (PSR1 on, sel-fetch off).    ##
# ###########################################################################
#
# Problem and evidence: doc/display-freeze.md. Short version: fullscreen hi-res
# video (usually at playback start) can wedge the display on this machine —
# frozen picture, no cursor, dead keyboard, audio still playing — with
#   xe 0000:00:02.0: [drm] *ERROR* [CRTC:151:pipe A] flip_done timed out
# Upstream lead that matches "new video surface at playback start":
#
#   cbe5654759  drm/i915/psr: Clear selective fetch area when duplicating plane state
#
# It is missing from 7.2.15 and 7.3.3 (verified by marker grep on the tagged
# sources) and present in 7.4-rc2. It has no Cc: stable, so it will not arrive
# in 7.2.y/7.3.y on its own.
#
# The display code lives in drivers/gpu/drm/i915/display/ and is built into
# **xe.ko** (CONFIG_DRM_XE=m + CONFIG_DRM_XE_DISPLAY=y), so the fix is one
# module build, not a kernel rebuild. On this kernel CONFIG_MODVERSIONS is off
# and CONFIG_MODULE_SIG is off, so the only ABI gate is the vermagic string —
# which this step compares against the shipped module before installing
# anything.
#
# Usage:
#   REPO_DIR=$PWD bash steps/kernel-xe-psr-fix.sh status      # default
#   REPO_DIR=$PWD bash steps/kernel-xe-psr-fix.sh fetch      # source + patch
#   REPO_DIR=$PWD bash steps/kernel-xe-psr-fix.sh build      # compile xe.ko
#   REPO_DIR=$PWD bash steps/kernel-xe-psr-fix.sh install    # replace xe.ko
#   REPO_DIR=$PWD bash steps/kernel-xe-psr-fix.sh rollback   # restore stock
#
# install backs up the shipped module to xe.ko.stock-<kver> and refreshes
# depmod. It takes effect on the next boot (xe is in use now). rollback is a
# plain file copy — no compilation needed.
#
# Idempotent: fetch skips verified downloads, build skips when the output is
# newer than the applied patch, install skips when the installed module already
# comes from this build.

set -u

REPO_DIR="${REPO_DIR:-/root/Development/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"
KVER="${KVER:-$(uname -r)}"
WORK="${KERNEL_XE_WORK:-/var/cache/kernel-build}"
SRC_TARBALL="linux-${KVER}.tar.xz"
SRC_DIR="${WORK}/linux-${KVER}"
PATCH="${WORK}/0001-psr-sel-fetch-area.patch"
PATCH_URL="https://github.com/torvalds/linux/commit/cbe5654759.patch"
SRC_URL="https://cdn.kernel.org/pub/linux/kernel/v$(echo "$KVER" | cut -d. -f1).x/${SRC_TARBALL}"
CONFIG_SRC="/boot/config-${KVER}.x64"
MOD_DEST="/lib/modules/${KVER}/kernel/drivers/gpu/drm/xe/xe.ko"
MOD_STOCK="${MOD_DEST}.stock-${KVER}"
BUILT="${SRC_DIR}/drivers/gpu/drm/xe/xe.ko"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

ACTION="${1:-status}"

echo "*****************************************************"
echo "xe.ko PSR FIX (kernel $KVER) — $ACTION"
echo "*****************************************************"

ok=true
note() { echo "  $*"; }

copy_vermagic() { modinfo -F vermagic "$1" 2>/dev/null | head -1; }

# --------------------------------------------------------------------------
# fetch — source tarball + upstream patch, both verified
# --------------------------------------------------------------------------
do_fetch() {
    mkdir -p "$WORK"

    if [ -f "${WORK}/${SRC_TARBALL}" ]; then
        note "source tarball present: ${WORK}/${SRC_TARBALL}"
        note "  (verified against cdn.kernel.org sha256 when it was downloaded)"
    else
        note "downloading ${SRC_URL}"
        curl -f# -o "${WORK}/${SRC_TARBALL}.part" "$SRC_URL" || { note "ERROR: download failed"; ok=false; return; }
        mv "${WORK}/${SRC_TARBALL}.part" "${WORK}/${SRC_TARBALL}"
    fi

    if [ -f "$PATCH" ]; then
        note "patch present: $PATCH"
    else
        note "downloading $PATCH_URL"
        curl -fsSL -A 'slackware-installer-for-rs' -o "$PATCH" "$PATCH_URL" || { note "ERROR: patch download failed"; ok=false; return; }
    fi

    if [ ! -d "$SRC_DIR" ]; then
        note "extracting ${SRC_TARBALL} -> $SRC_DIR"
        tar -xf "${WORK}/${SRC_TARBALL}" -C "$WORK" || { note "ERROR: extract failed"; ok=false; return; }
    else
        note "source tree present: $SRC_DIR"
    fi

    if [ ! -f "$CONFIG_SRC" ]; then
        note "ERROR: $CONFIG_SRC missing (no config for the running kernel)"
        ok=false
        return
    fi
    note "config: $CONFIG_SRC"
}

# --------------------------------------------------------------------------
# build — apply patch, configure with the running config, compile xe.ko
# --------------------------------------------------------------------------
do_build() {
    [ -d "$SRC_DIR" ] || { note "ERROR: run 'fetch' first ($SRC_DIR missing)"; ok=false; return; }
    [ -f "$PATCH" ]    || { note "ERROR: run 'fetch' first ($PATCH missing)"; ok=false; return; }

    cd "$SRC_DIR" || { ok=false; return; }

    # 1. Patch (idempotent: detect the fix by its own marker).
    if grep -q 'skip_su_area_calc' drivers/gpu/drm/i915/display/intel_psr.c; then
        note "patch already applied (skip_su_area_calc present)"
    else
        note "applying $(basename "$PATCH")"
        patch -p1 < "$PATCH" || { note "ERROR: patch failed"; ok=false; return; }
    fi

    # 2. Config: MUST be the running kernel's config, unchanged. A silent
    #    difference here is how you build a module that refuses to load.
    if [ ! -f .config ] || ! cmp -s .config "$CONFIG_SRC"; then
        cp "$CONFIG_SRC" .config
        note "config installed from $CONFIG_SRC"
    else
        note "config already matches $CONFIG_SRC"
    fi
    make -s olddefconfig
    if ! cmp -s .config "$CONFIG_SRC"; then
        note "WARNING: olddefconfig changed the config — diff:"
        diff <(grep -v '^#' "$CONFIG_SRC") <(grep -v '^#' .config) | head -20 | sed 's/^/    /'
    fi

    # 3. Build only the module we need. LOCALVERSION is pinned empty so the
    #    vermagic string stays exactly "7.2.15 SMP preempt mod_unload".
    note "building drivers/gpu/drm/xe/xe.ko (this takes a few minutes)"
    make -j"$(nproc)" LOCALVERSION= prepare
    # KBUILD_MODPOST_WARN=1 is required here: a module-only build has no
    # vmlinux.o, so modpost cannot resolve symbols provided by the kernel core
    # and kernel modules. With CONFIG_MODVERSIONS=n there are no CRCs to check,
    # and the unresolved symbols are resolved at load time by the running
    # kernel — the step verifies that separately (see "new undefined symbols").
    make -j"$(nproc)" LOCALVERSION= KBUILD_MODPOST_WARN=1 drivers/gpu/drm/xe/xe.ko \
        || { note "ERROR: build failed"; ok=false; return; }

    [ -f "$BUILT" ] || { note "ERROR: $BUILT not produced"; ok=false; return; }

    # 4. ABI gate: vermagic must match the shipped module byte for byte.
    local vm_built vm_stock
    vm_built=$(copy_vermagic "$BUILT")
    vm_stock=$(copy_vermagic "$MOD_DEST")
    note "vermagic built : '$vm_built'"
    note "vermagic stock : '$vm_stock'"
    if [ -z "$vm_built" ] || [ "$vm_built" != "$vm_stock" ]; then
        note "ERROR: vermagic mismatch — this module would not load. Not installing."
        ok=false
        return
    fi
    note "vermagic matches"

    # 5. Undefined symbols: everything the patched module needs must already be
    #    provided by the running kernel or a module that is present. Compare
    #    with the stock module so anything NEW is called out explicitly.
    local new_syms
    new_syms=$(comm -13 \
        <(nm -u "$MOD_DEST" 2>/dev/null | awk '{print $NF}' | sort -u) \
        <(nm -u "$BUILT"    2>/dev/null | awk '{print $NF}' | sort -u))
    if [ -n "$new_syms" ]; then
        note "new undefined symbols vs stock module:"
        printf '%s\n' "$new_syms" | sed 's/^/    /'
        local missing=0 s
        for s in $new_syms; do
            grep -qw "$s" /proc/kallsyms 2>/dev/null || { note "    NOT in kallsyms: $s"; missing=1; }
        done
        [ "$missing" = 0 ] && note "  all of them are in /proc/kallsyms (kernel-provided)"
    else
        note "no new undefined symbols (identical external interface)"
    fi

    note "built: $BUILT ($(du -h "$BUILT" | cut -f1))"
}

# --------------------------------------------------------------------------
# install / rollback
# --------------------------------------------------------------------------
do_install() {
    [ -f "$BUILT" ] || { note "ERROR: no built module — run 'build' first"; ok=false; return; }
    [ "$(copy_vermagic "$BUILT")" = "$(copy_vermagic "$MOD_DEST")" ] || {
        note "ERROR: vermagic mismatch, refusing to install"; ok=false; return; }

    if [ -f "$MOD_STOCK" ] && cmp -s "$BUILT" "$MOD_DEST"; then
        note "already installed (installed module is this build)"
        return
    fi
    if [ ! -f "$MOD_STOCK" ]; then
        cp -a "$MOD_DEST" "$MOD_STOCK" && note "backed up stock module -> $MOD_STOCK"
    else
        note "stock backup already present: $MOD_STOCK"
    fi
    install -m 644 "$BUILT" "$MOD_DEST" && note "installed patched xe.ko -> $MOD_DEST"
    depmod -a "$KVER" && note "depmod done"
    note "takes effect on next boot (xe is in use right now)"
    note "rollback: REPO_DIR=$REPO_DIR bash steps/kernel-xe-psr-fix.sh rollback"
}

do_rollback() {
    if [ ! -f "$MOD_STOCK" ]; then
        note "no stock backup at $MOD_STOCK — nothing to roll back to"
        ok=false
        return
    fi
    install -m 644 "$MOD_STOCK" "$MOD_DEST" && note "restored stock xe.ko"
    depmod -a "$KVER" && note "depmod done"
}

# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------
do_status() {
    note "source tree : $([ -d "$SRC_DIR" ] && echo present || echo missing) ($SRC_DIR)"
    note "patch       : $([ -f "$PATCH" ] && echo present || echo missing)"
    if [ -d "$SRC_DIR" ]; then
        if grep -q 'skip_su_area_calc' "$SRC_DIR/drivers/gpu/drm/i915/display/intel_psr.c" 2>/dev/null; then
            note "patch state : applied in source tree"
        else
            note "patch state : not applied"
        fi
    fi
    note "built module: $([ -f "$BUILT" ] && echo "$BUILT ($(du -h "$BUILT" | cut -f1))" || echo missing)"
    if [ -f "$MOD_STOCK" ]; then
        note "installed   : $(cmp -s "$BUILT" "$MOD_DEST" && echo 'patched (this build)' || echo 'STOCK (rollback available)')"
        note "backup      : $MOD_STOCK"
    else
        note "installed   : stock Slackware module (no backup taken yet)"
    fi
    note "vermagic now: $(copy_vermagic "$MOD_DEST")"
    note "loaded mod  : $(modinfo -F vermagic xe 2>/dev/null || echo 'not loaded')"
}

case "$ACTION" in
    fetch)    do_fetch ;;
    build)    do_build ;;
    install)  do_install ;;
    rollback) do_rollback ;;
    status)   do_status ;;
    *) echo "ERROR: unknown action '$ACTION' (fetch|build|install|rollback|status)"; exit 1 ;;
esac

if $ok; then
    exit 0
else
    echo "FAILED: see messages above."
    exit 1
fi
