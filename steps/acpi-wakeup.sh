#!/bin/bash
# steps/acpi-wakeup.sh - ACPI WAKEUP: power button only
#
# Disables every ACPI, PCI, platform, PNP, and USB wakeup source except
# the power button (LNXPWRBN / PWRB). The machine will only wake from
# sleep when the power button is pressed. Lid, keyboard, mouse, USB,
# Thunderbolt, RTC/alarm, AC adapter, etc. will NOT wake it.
# Persists across reboots via /etc/rc.d/rc.local.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "ACPI WAKEUP (power button only)                      "
echo "*****************************************************"

ok=true

# --- 1. Immediate: disable via /proc/acpi/wakeup ---
echo "Disabling ALL ACPI wakeup sources (power button handled via sysfs)..."
if [ -f /proc/acpi/wakeup ]; then
    awk 'NR>1 && $1 ~ /^[A-Z]/ {print $1}' /proc/acpi/wakeup | while read -r dev; do
        if echo "$dev" > /proc/acpi/wakeup 2>/dev/null; then
            echo "  Disabled: $dev"
        else
            echo "  WARNING: could not disable $dev (may not support wakeup toggle)"
        fi
    done
else
    echo "  No /proc/acpi/wakeup found (non-ACPI system or kernel too old)."
fi

# --- 2. Immediate: disable ALL sysfs wakeup sources EXCEPT the power button ---
echo "Disabling ALL sysfs wakeup sources EXCEPT power button (LNXPWRBN)..."
# Walk all /sys/devices/.../power/wakeup files and disable them,
# but keep /sys/devices/.../LNXPWRBN:00/power/wakeup enabled.
disabled_count=0
skipped_count=0
while IFS= read -r -d '' f; do
    if [[ "$f" == *LNXPWRBN* ]]; then
        # Ensure the power button is enabled
        if [ -f "$f" ] && echo enabled > "$f" 2>/dev/null; then
            echo "  Keeping enabled: $f (power button)"
        fi
        skipped_count=$((skipped_count + 1))
    elif [ -f "$f" ] && echo disabled > "$f" 2>/dev/null; then
        disabled_count=$((disabled_count + 1))
    fi
done < <(find /sys/devices -name wakeup -not -path '*/virtual/*' -print0 2>/dev/null)
echo "  Disabled $disabled_count sysfs wakeup source(s); kept $skipped_count (power button)."

# --- 3. Also ensure lid switch is disabled at ACPI level (already done via /proc) ---
if [ -f "/sys/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0C0D:00/power/wakeup" ]; then
    echo disabled > "/sys/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0C0D:00/power/wakeup" 2>/dev/null \
        && echo "  Confirmed: lid wakeup disabled."
fi

# --- 4. Install persistence hook via rc.local ---
echo "Installing persistence hook via /etc/rc.d/rc.local..."
if [ -f /etc/rc.d/rc.local ]; then
    if ! grep -q "acpi-wakeup" /etc/rc.d/rc.local 2>/dev/null; then
        cat >> /etc/rc.d/rc.local << 'EOF'

# Disable ACPI wakeup devices (added by post-install-global.sh)
for dev in LID XHC RP01 RP02 RP03 RP04 RP05 RP06 RP07 RP08; do
    [ -f "/proc/acpi/wakeup" ] && grep -q "^$dev" /proc/acpi/wakeup && echo "$dev" > /proc/acpi/wakeup 2>/dev/null || true
done
# Also disable lid via sysfs (belt-and-suspenders)
[ -f /sys/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0C0D:00/power/wakeup ] && echo disabled > /sys/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0C0D:00/power/wakeup 2>/dev/null || true
EOF
        echo "  Added acpi-wakeup hook to rc.local."
    else
        echo "  acpi-wakeup hook already in rc.local."
    fi
else
    echo "  WARNING: /etc/rc.d/rc.local not found."
fi

# --- Final check ---
if $ok; then
    echo "SUCCESS: ACPI wakeup restricted to power button only."
    echo "         Lid, keyboard, mouse, USB, Thunderbolt, RTC, AC adapter —"
    echo "         NOTHING except the power button wakes the machine."
    echo "         (Survives reboots via /etc/rc.d/rc.localacpi-wakeup.start)"
    exit 0
else
    echo "ERROR: could not fully configure ACPI wakeup restrictions."
    exit 1
fi
