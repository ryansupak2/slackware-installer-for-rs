#!/bin/bash
# steps/touchscreen-off.sh — DISABLE TOUCHSCREEN (console + X)
#
# Makes touchscreen hardware completely inert at the kernel input layer, so it
# is gone in the text console ("Shell") and in X/dwm later on.
#
# Two layers, both deployed here:
#   1. /usr/local/bin/touchscreen-off — unbinds every device tagged
#      ID_INPUT_TOUCHSCREEN=1 from its owning driver (HID instance / i2c client
#      / USB interface). The /dev/input node disappears entirely.
#   2. /etc/udev/rules.d/99-touchscreen-off.rules — runs the helper on every
#      touchscreen input device add (boot + hotplug) and additionally sets
#      LIBINPUT_IGNORE_DEVICE=1 as a belt-and-braces guard, in case an unbind
#      is ever refused.
#
# Touchpads are NOT affected (they are INPUT_PROP_POINTER, not _DIRECT, so
# udev does not tag them ID_INPUT_TOUCHSCREEN).
#
# Idempotent: re-running rewrites identical files and the helper no-ops once
# no touchscreen input node is left.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "DISABLE TOUCHSCREEN"
echo "*****************************************************"

ok=true

HELPER_SRC="$REPO_DIR/scripts/touchscreen-off.sh"
HELPER_DST="/usr/local/bin/touchscreen-off"
RULE_SRC="$REPO_DIR/dotfiles/system/99-touchscreen-off.rules"
RULE_DST="/etc/udev/rules.d/99-touchscreen-off.rules"

# ── 1. Helper ──────────────────────────────────────────────────────────
if [ ! -f "$HELPER_SRC" ]; then
    echo "ERROR: $HELPER_SRC missing."
    ok=false
elif cmp -s "$HELPER_SRC" "$HELPER_DST" && [ -x "$HELPER_DST" ]; then
    echo "  touchscreen helper already deployed — skipping"
else
    install -m 0755 "$HELPER_SRC" "$HELPER_DST" || ok=false
    echo "  $HELPER_DST deployed"
fi

# ── 2. udev rule ───────────────────────────────────────────────────────
if [ ! -f "$RULE_SRC" ]; then
    echo "ERROR: $RULE_SRC missing."
    ok=false
elif cmp -s "$RULE_SRC" "$RULE_DST"; then
    echo "  udev rule already deployed — skipping"
else
    install -m 0644 "$RULE_SRC" "$RULE_DST" || ok=false
    echo "  $RULE_DST deployed"
fi

if $ok; then
    # Reload rules so the rule applies to devices added from now on.
    udevadm control --reload-rules >/dev/null 2>&1 || true

    # Disable touchscreens that are present right now (this boot).
    if [ -x "$HELPER_DST" ]; then
        "$HELPER_DST" || ok=false
    fi
fi

# ── 3. Verify ──────────────────────────────────────────────────────────
ts_left=0
for dev in /dev/input/event*; do
    [ -e "$dev" ] || continue
    if udevadm info -q property -n "$dev" 2>/dev/null | grep -q '^ID_INPUT_TOUCHSCREEN=1'; then
        echo "  STILL PRESENT: $dev ($(cat /sys/class/input/$(basename "$dev")/device/name 2>/dev/null))"
        ts_left=$((ts_left + 1))
    fi
done

if [ "$ts_left" -eq 0 ]; then
    echo "  Verified: no touchscreen input device present."
else
    echo "  WARNING: $ts_left touchscreen device(s) still present."
    ok=false
fi

if $ok; then
    echo "SUCCESS: Touchscreen disabled (console + X)."
    exit 0
else
    echo "ERROR: Touchscreen disable incomplete."
    exit 1
fi
