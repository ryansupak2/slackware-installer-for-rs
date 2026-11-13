#!/bin/bash
# steps/wakeup-power-only.sh — disable all wake sources except power button + lid
#
# The lid switch (PNP0C0D / LID*) is deliberately KEPT: lid close suspends the
# machine (steps/screen-locking.sh), so lid open must be able to wake it again.
#
# Idempotent: safe to re-run. Must be re-applied after every boot.

set -eu

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "WAKEUP — POWER BUTTON ONLY"
echo "*****************************************************"

echo "Disabling all ACPI wake sources except power button + lid..."

# Disable everything on the ACPI wakeup table
for dev in $(grep "\*enabled" /proc/acpi/wakeup | awk '{print $1}'); do
    case "$dev" in PWRB|SLPB|LID*) continue ;; esac
    echo "$dev" > /proc/acpi/wakeup 2>/dev/null || true
done

# Disable every sysfs wakeup source EXCEPT the power button and the lid.
# The lid MUST stay enabled: lid close suspends, so lid open is the only
# touch-free way back in. Forgetting this exception left PNP0C0D disabled
# after an install, which makes a suspended machine a brick until the power
# button is held (that is exactly the bug this loop used to cause).
lid_wakeup=""
for wakefile in $(find /sys/devices -name "wakeup" -path "*/power/*" 2>/dev/null); do
    case "$wakefile" in
        *PNP0C0D*|*LNXPWRBN*|*PWRB*)
            echo enabled > "$wakefile" 2>/dev/null || true
            case "$wakefile" in *PNP0C0D*) lid_wakeup=$wakefile ;; esac
            continue ;;
    esac
    if [ "$(cat "$wakefile" 2>/dev/null)" = "enabled" ]; then
        echo "disabled" > "$wakefile" 2>/dev/null || true
    fi
done

# Verify
remaining=$(grep "\*enabled" /proc/acpi/wakeup | wc -l)
echo "Remaining enabled: $remaining"
if [ -n "$lid_wakeup" ]; then
    echo "  lid wake source: $lid_wakeup -> $(cat "$lid_wakeup" 2>/dev/null)"
else
    echo "  lid wake source: not present (EC handles lid wake without sysfs)"
fi

# --- Sleep state: s2idle (what the firmware implements), never deep/S3 ---
# This is NOT a wake-source control. It lives here because the old version
# forced `deep` to make the sysfs wakeup restrictions "bite" - and that is
# exactly what broke lid close on this machine: the last line logged before
# the hang was 'PM: suspend entry (deep)', and the next line is the next
# boot, hours later, after a power-button reset.
# The firmware advertises ACPI low-power S0 idle (dmesg: "Low-power S0 idle
# used by default for system suspend"), i.e. it wants s2idle. Ask for that;
# deep is only the fallback on kernels/firmware without s2idle.
if grep -qw s2idle /sys/power/mem_sleep 2>/dev/null; then
    if echo s2idle > /sys/power/mem_sleep 2>/dev/null; then
        echo "  mem_sleep set to: s2idle (modern standby - what this firmware implements)"
    else
        echo "  WARNING: could not set mem_sleep to s2idle"
    fi
else
    echo "  NOTE: s2idle not offered; leaving mem_sleep=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/power/mem_sleep 2>/dev/null)"
fi

# Deploy a boot-time enforcer
cat > /usr/local/bin/wakeup-power-only << 'EOF'
#!/bin/sh
# Re-apply wake source restrictions after resume or boot
for dev in $(grep "\*enabled" /proc/acpi/wakeup 2>/dev/null | awk '{print $1}'); do
    echo "$dev" > /proc/acpi/wakeup 2>/dev/null || true
done
for wakefile in $(find /sys/devices -name "wakeup" -path "*/power/*" 2>/dev/null); do
    # Never disable the power button, and never the lid (lid open must resume)
    case "$wakefile" in *LNXPWRBN*|*PWRB*|*PNP0C0D*) echo enabled > "$wakefile" 2>/dev/null; continue ;; esac
    if [ "$(cat "$wakefile" 2>/dev/null)" = "enabled" ]; then
        echo "disabled" > "$wakefile" 2>/dev/null || true
    fi
done
# Sleep state: s2idle when the kernel offers it (same reason as the step:
# forcing deep/S3 is what used to hang lid close on this machine).
if grep -qw s2idle /sys/power/mem_sleep 2>/dev/null; then
    echo s2idle > /sys/power/mem_sleep 2>/dev/null || true
fi
EOF
chmod +x /usr/local/bin/wakeup-power-only

# Hook into elogind post-resume to keep wake sources disabled after sleep
HOOK="/lib64/elogind/system-sleep/wakeup-power-only.sh"
cat > "$HOOK" << 'EOF'
#!/bin/bash
case "$1" in
  post)
    /usr/local/bin/wakeup-power-only
    ;;
esac
EOF
chmod +x "$HOOK"

# Boot-time enforcement via rc.local
if ! grep -q "wakeup-power-only" /etc/rc.d/rc.local 2>/dev/null; then
    echo "/usr/local/bin/wakeup-power-only" >> /etc/rc.d/rc.local
    echo "  Added to /etc/rc.d/rc.local"
else
    echo "  Already in /etc/rc.d/rc.local"
fi

echo "  wakeup-power-only deployed to /usr/local/bin/wakeup-power-only"
echo "  elogind post-resume hook deployed to $HOOK"

echo "SUCCESS: Only the power button and the lid will wake the machine."
echo "         Sleep state: s2idle (modern standby). deep/S3 never resumes here:"
echo "         see doc/screen-locking.md. Change it with 'power set sleep deep'."
exit 0
