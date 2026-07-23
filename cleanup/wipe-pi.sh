#!/bin/bash
# cleanup/wipe-pi.sh — COMPLETELY REMOVE PI CODING AGENT
#
# Removes the pi node installation, config, extensions, and all runtime data.
# This is a DESTRUCTIVE cleanup — NOT part of the main installer pipeline.
# pi can be reinstalled later with: steps/pi-clean-reinstall.sh
#
# Usage:  bash cleanup/wipe-pi.sh

set -euo pipefail

LOG_DIR="/var/log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/${USER:-root}-wipe-pi-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=================================================="
echo "WIPE PI CODING AGENT — $(date)"
echo "Log: $LOG_FILE"
echo "=================================================="
echo ""

# ── Safety check: refuse if pi is currently running ───────────
if pgrep -f 'pi' >/dev/null 2>&1; then
    # pi itself might be the process running this script. Be smarter.
    RUNNING=$(pgrep -f 'pi' | grep -v "$$" || true)
    if [ -n "$RUNNING" ]; then
        echo "WARNING: pi process(es) found: $RUNNING"
        echo "It's safest to run this from a plain shell, not inside pi."
        read -p "Continue anyway? (y/N): " confirm
        [[ "$confirm" != [yY] ]] && exit 0
    fi
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
# 1. pi node installation (~341 MB)
# ═══════════════════════════════════════════════════════════════
echo "--- pi node runtime ---"
if [ -d /usr/local/node-v* ]; then
    for d in /usr/local/node-v*; do
        [ -d "$d" ] || continue
        echo "  REMOVE: $d ($(du -sh "$d" 2>/dev/null | cut -f1))"
        rm -rf "$d"
        REMOVED=$((REMOVED + 1))
    done
else
    SKIPPED=$((SKIPPED + 1))
fi

# ═══════════════════════════════════════════════════════════════
# 2. pi config directory (~/.pi)
# ═══════════════════════════════════════════════════════════════
echo "--- pi config ---"
maybe_rm /root/.pi

# ═══════════════════════════════════════════════════════════════
# 3. pi runtime data
# ═══════════════════════════════════════════════════════════════
echo "--- pi runtime data ---"
maybe_rm /root/.local/share/pi-node

# ═══════════════════════════════════════════════════════════════
# 4. Stale symlinks in /usr/local/bin (pi, node, npm, npx, corepack)
#    Only remove if they point into the deleted node-v* tree
# ═══════════════════════════════════════════════════════════════
echo "--- stale symlinks in /usr/local/bin ---"
for link in pi node npm npx corepack; do
    target="/usr/local/bin/$link"
    if [ -L "$target" ]; then
        dest=$(readlink -f "$target" 2>/dev/null || true)
        if [ ! -e "$dest" ]; then
            echo "  REMOVE (broken): $target -> $dest"
            rm -f "$target"
            REMOVED=$((REMOVED + 1))
        fi
    fi
done

# 5. Done
# ═══════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════════
echo ""
echo "=================================================="
echo "WIPE PI — COMPLETE"
echo "  Removed:  $REMOVED"
echo "  Skipped:  $SKIPPED (already gone)"
echo "=================================================="
echo ""
echo "To reinstall pi:  REPO_DIR=$(pwd) bash steps/pi-clean-reinstall.sh"
