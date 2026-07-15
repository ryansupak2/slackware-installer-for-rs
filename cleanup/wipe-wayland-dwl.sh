#!/bin/bash
# cleanup/wipe-wayland-dwl.sh — COMPLETELY REMOVE WAYLAND + DWL
#
# Removes the dwl Wayland compositor, somebar, wlroots, libdisplay-info,
# and all related build artifacts. Leaves X11/dwm and shared libraries
# (wayland, libdrm, pixman, xkbcommon, libinput) untouched.
#
# This is a DESTRUCTIVE cleanup — NOT part of the main installer pipeline.
# Run manually when you want to purge Wayland from the system.
#
# Usage:  bash cleanup/wipe-wayland-dwl.sh

set -euo pipefail

LOG_DIR="/var/log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/${USER:-root}-wipe-wayland-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=================================================="
echo "WIPE WAYLAND + DWL — $(date)"
echo "Log: $LOG_FILE"
echo "=================================================="
echo ""

# ── Safety check: refuse if dwl is currently running ──────────
if pgrep -x dwl >/dev/null 2>&1; then
    echo "ERROR: dwl is currently running. Switch to dwm/X11 first, then re-run."
    exit 1
fi

REMOVED=0
SKIPPED=0

maybe_rm() {
    local target="$1"
    if [ -e "$target" ] || [ -L "$target" ]; then
        echo "  REMOVE: $target"
        rm -rf "$target"
        REMOVED=$((REMOVED + 1))
    else
        SKIPPED=$((SKIPPED + 1))
    fi
}

# ═══════════════════════════════════════════════════════════════
# 1. dwl binaries (Wayland compositor)
# ═══════════════════════════════════════════════════════════════
echo "--- dwl binaries ---"
maybe_rm /usr/local/bin/dwl
maybe_rm /usr/local/bin/dwl-start
maybe_rm /usr/local/bin/dwl-status
maybe_rm /usr/local/bin/dwl-status.sh

# ═══════════════════════════════════════════════════════════════
# 2. somebar (dwl companion status bar)
# ═══════════════════════════════════════════════════════════════
echo "--- somebar ---"
maybe_rm /usr/local/bin/somebar

# ═══════════════════════════════════════════════════════════════
# 3. dwl + somebar source & stamp directories
# ═══════════════════════════════════════════════════════════════
echo "--- dwl/somebar sources ---"
maybe_rm /usr/local/src/suckless/dwl
maybe_rm /usr/local/src/suckless/dwl-stamp
maybe_rm /usr/local/src/suckless/somebar
maybe_rm /usr/local/src/suckless/somebar-stamp
maybe_rm /usr/local/src/suckless/somebar-orig

# ═══════════════════════════════════════════════════════════════
# 4. dwl session file, man pages
# ═══════════════════════════════════════════════════════════════
echo "--- session/man pages ---"
maybe_rm /usr/local/share/wayland-sessions/dwl.desktop
maybe_rm /usr/local/share/man/man1/dwl.1
maybe_rm /usr/local/share/man/man1/somebar.1

# ═══════════════════════════════════════════════════════════════
# 5. wlroots 0.19 (only used by dwl)
# ═══════════════════════════════════════════════════════════════
echo "--- wlroots ---"
maybe_rm /usr/lib64/libwlroots-0.19.so
maybe_rm /usr/lib64/pkgconfig/wlroots-0.19.pc
# wlroots headers (only wlroots-0.19 exists here; if empty after, rmdir is fine)
for d in /usr/include/wlroots-*; do
    [ -e "$d" ] && maybe_rm "$d"
done

# ═══════════════════════════════════════════════════════════════
# 6. libdisplay-info (only used by wlroots)
# ═══════════════════════════════════════════════════════════════
echo "--- libdisplay-info ---"
maybe_rm /usr/lib64/libdisplay-info.so
maybe_rm /usr/lib64/libdisplay-info.so.4
maybe_rm /usr/lib64/libdisplay-info.so.0.4.0
maybe_rm /usr/lib64/pkgconfig/libdisplay-info.pc
maybe_rm /usr/include/libdisplay-info

# ═══════════════════════════════════════════════════════════════
# 7. Source build directories (wayland, wayland-protocols, wlroots, libdisplay-info)
#    Built from source by wayland-base.sh under /usr/local/src/wayland/
# ═══════════════════════════════════════════════════════════════
echo "--- wayland-base source build dirs ---"
maybe_rm /usr/local/src/wayland
maybe_rm /usr/local/src/libdisplay-info

# ═══════════════════════════════════════════════════════════════
# 8. Clean stale soname symlinks that point to removed libs
# ═══════════════════════════════════════════════════════════════
echo "--- broken symlink cleanup ---"
find /usr/lib64 -name 'libwlroots*' -xtype l -exec rm -v {} \; 2>/dev/null || true
find /usr/lib64 -name 'libdisplay-info*' -xtype l -exec rm -v {} \; 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════
# 9. rc.local seatd entries (left by wayland-base)
# ═══════════════════════════════════════════════════════════════
echo "--- rc.local seatd cleanup ---"
if [ -f /etc/rc.d/rc.local ] && grep -q "seatd" /etc/rc.d/rc.local 2>/dev/null; then
    echo "  NOTE: /etc/rc.d/rc.local contains seatd entries."
    echo "  These were added by wayland-base. Review manually if you want to remove them:"
    grep -n 'seatd\|Wayland seatd' /etc/rc.d/rc.local || true
    echo "  (Leave them — they're harmless no-ops when seatd isn't running.)"
fi

# ═══════════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════════
ldconfig 2>/dev/null || true

echo ""
echo "=================================================="
echo "WIPE WAYLAND + DWL — COMPLETE"
echo "  Removed:  $REMOVED"
echo "  Skipped:  $SKIPPED (already gone)"
echo "  Kept:     wayland libs, libdrm, pixman, xkbcommon, libinput (X11 needs them)"
echo "  Kept:     seatd (standalone, not removed)"
echo "  Kept:     toggle-bar, toggle-hide-mode, temp-msg (shared with dwm)"
echo "=================================================="
echo ""
echo "dwm/X11 is unaffected. Verify:  pgrep dwm"
