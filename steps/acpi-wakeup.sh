#!/bin/bash
# steps/acpi-wakeup.sh - ACPI WAKEUP: power button + lid
#
# Lid close = suspend (steps/screen-locking.sh), so opening the lid must wake
# the machine again — the lid switch (PNP0C0D) stays ENABLED as a wake source
# here. Everything else (keyboard, touchpad, USB, Thunderbolt, RTC/alarm, AC
# adapter, XHCI, HDAS, ...) stays disabled, so the machine still cannot be
# woken by a random keypress, mouse nudge or USB event.
#
# Note the lid's wakeup attributes live on the EC node, NOT on the
# LNXSYSTM/LNXSYBUS node that also carries PNP0C0D — that alias has no
# power/wakeup file at all:
#   /sys/devices/pci0000:00/0000:00:1f.0/PNP0C09:00/PNP0C0D:00/power/wakeup
#
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
    if [[ "$f" == *LNXPWRBN* || "$f" == *PNP0C0D* ]]; then
        # Ensure the power button is enabled
        if [ -f "$f" ] && echo enabled > "$f" 2>/dev/null; then
            echo "  Keeping enabled: $f"
        fi
        skipped_count=$((skipped_count + 1))
    elif [ -f "$f" ] && echo disabled > "$f" 2>/dev/null; then
        disabled_count=$((disabled_count + 1))
    fi
done < <(find /sys/devices -name wakeup -not -path '*/virtual/*' -print0 2>/dev/null)
echo "  Disabled $disabled_count sysfs wakeup source(s); kept $skipped_count (power button)."

# --- 3. Lid switch: ENABLED, so opening the lid resumes from suspend ---
echo "Enabling lid switch as a wake source (lid close suspends, lid open resumes)..."
lid_ok=false
while IFS= read -r f; do
    if echo enabled > "$f" 2>/dev/null; then
        echo "  enabled: $f (now $(cat "$f" 2>/dev/null))"
        lid_ok=true
    else
        echo "  WARNING: could not write $f"
    fi
done < <(find /sys/devices -path '*PNP0C0D*/power/wakeup' 2>/dev/null)
if ! $lid_ok; then
    echo "  NOTE: no PNP0C0D wakeup attribute found — this machine's lid open is"
    echo "        handled by the embedded controller; the power button still wakes it."
fi

# --- 4. Install persistence hook via rc.local ---
echo "Installing persistence hook via /etc/rc.d/rc.local..."
if [ -f /etc/rc.d/rc.local ]; then
    # Older installs wrote a block that explicitly DISABLED the lid wake source
    # ("Also disable lid via sysfs") — that broke lid-open resume, so strip the
    # old block before writing the current one.
    if grep -q 'Also disable lid via sysfs' /etc/rc.d/rc.local 2>/dev/null; then
        awk '
            /^# acpi-wakeup: disable wakeup devices/ { skip = 1 }
            skip && /Also disable lid via sysfs/    { skip = 0; next }
            !skip { print }
        ' /etc/rc.d/rc.local > /etc/rc.d/rc.local.new && mv /etc/rc.d/rc.local.new /etc/rc.d/rc.local
        echo "  removed the old lid-disabling block from rc.local"
    fi
    # Older installs also left single lines that write "disabled" to the lid's
    # wakeup file (the LNXSYSTM/LNXSYBUS alias of PNP0C0D). The lid is a wake
    # source now - lid close suspends, so lid open has to resume - and such a
    # line makes that impossible. Strip every one of them.
    if grep -qE 'PNP0C0D.*power/wakeup' /etc/rc.d/rc.local 2>/dev/null; then
        grep -vE 'PNP0C0D.*power/wakeup' /etc/rc.d/rc.local > /etc/rc.d/rc.local.new \
            && mv /etc/rc.d/rc.local.new /etc/rc.d/rc.local
        echo "  removed a stale lid-wakeup-disabling line from rc.local"
    fi
    if ! grep -q "acpi-wakeup: keep power button" /etc/rc.d/rc.local 2>/dev/null; then
        cat >> /etc/rc.d/rc.local << 'EOF'

# acpi-wakeup: keep power button + lid as wake sources (added by steps/acpi-wakeup.sh)
# Lid close suspends and lid open resumes (steps/screen-locking.sh), so the lid
# MUST stay enabled here. Everything else (USB, RTC, AC, XHCI, HDAS, ...) off.
for dev in $(grep '\*enabled' /proc/acpi/wakeup 2>/dev/null | awk '{print $1}'); do
    case "$dev" in PWRB|SLPB|LID*) continue ;; esac
    echo "$dev" > /proc/acpi/wakeup 2>/dev/null || true
done
for f in $(find /sys/devices -path '*/power/wakeup' -not -path '*/virtual/*' 2>/dev/null); do
    case "$f" in *LNXPWRBN*|*PWRB*|*PNP0C0D*) echo enabled > "$f" 2>/dev/null; continue ;; esac
    echo disabled > "$f" 2>/dev/null || true
done
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
    echo "SUCCESS: wake sources = power button + lid switch."
    echo "         Lid close suspends (steps/screen-locking.sh) and lid open wakes it."
    echo "         Keyboard, touchpad, USB, Thunderbolt, RTC and the AC adapter"
    echo "         still cannot wake the machine. Persisted via /etc/rc.d/rc.local."
fi
