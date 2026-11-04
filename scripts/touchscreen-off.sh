#!/bin/sh
# scripts/touchscreen-off.sh — completely disable touchscreens.
#
# Deployed by steps/touchscreen-off.sh to /usr/local/bin/touchscreen-off and
# run from udev on every touchscreen input device (boot + hotplug).
#
# How: touchscreens are detected via the udev property ID_INPUT_TOUCHSCREEN=1
# (derived by udev from the evdev INPUT_PROP_DIRECT bit, so touchpads are NOT
# matched). For each match the owning kernel device (the HID instance, i2c
# client or USB interface that created the input node) is unbound from its
# driver. The input node then ceases to exist, which covers *every* consumer:
#
#   - Linux text console (no /dev/input/event* node at all)
#   - libinput / Xorg / xinput / dwm (they never see a device)
#
# Touchpads and keyboards are left untouched: they are INPUT_PROP_POINTER, not
# INPUT_PROP_DIRECT, so udev does not tag them.
#
# Idempotent: if no touchscreen is present (already unbound), it exits 0.

set -u

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
say() { [ "$QUIET" -eq 1 ] || echo "$@"; }

command -v udevadm >/dev/null 2>&1 || { say "touchscreen-off: udevadm missing"; exit 0; }

found=0
disabled=0

for dev in /dev/input/event*; do
    [ -e "$dev" ] || continue
    props=$(udevadm info -q property -n "$dev" 2>/dev/null) || continue
    case "$props" in
        *ID_INPUT_TOUCHSCREEN=1*) ;;
        *) continue ;;
    esac
    found=$((found + 1))

    # /sys/class/input/eventN/device -> .../<hid instance or i2c/usb client>/input/inputN
    input_dir=$(readlink -f "/sys/class/input/$(basename "$dev")/device" 2>/dev/null)
    [ -n "$input_dir" ] && [ -d "$input_dir" ] || continue
    # /sys/class/input/eventN/device -> .../<owner>/input/inputN; the owner is
    # the first ancestor that has a driver symlink (HID instance, i2c client,
    # USB interface). The bare "input/" grouping dir has no driver.
    owner=
    d=$(dirname "$input_dir")
    while [ "$d" != "/" ] && [ -n "$d" ]; do
        if [ -e "$d/driver" ]; then owner=$d; break; fi
        d=$(dirname "$d")
    done
    [ -n "$owner" ] || continue
    drv=$(basename "$(readlink -f "$owner/driver" 2>/dev/null)")
    bus=$(basename "$(readlink -f "$owner/subsystem" 2>/dev/null)")
    [ -n "$drv" ] && [ -n "$bus" ] || continue

    unbind="/sys/bus/$bus/drivers/$drv/unbind"
    [ -w "$unbind" ] || continue

    name=$(basename "$owner")
    say "touchscreen-off: unbinding $name from $drv ($bus)"
    if printf '%s' "$name" > "$unbind" 2>/dev/null; then
        disabled=$((disabled + 1))
    else
        say "touchscreen-off: WARNING: failed to unbind $name"
    fi
done

[ "$found" -eq 0 ] && say "touchscreen-off: no touchscreen present (already disabled)"
[ "$disabled" -gt 0 ] && say "touchscreen-off: disabled $disabled touchscreen(s)"
exit 0
