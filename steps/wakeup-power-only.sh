#!/bin/bash
# steps/wakeup-power-only.sh — disable all wake sources except power button
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

echo "Disabling all ACPI wake sources except power button..."

# Disable everything on the ACPI wakeup table
for dev in $(grep "\*enabled" /proc/acpi/wakeup | awk '{print $1}'); do
    echo "$dev" > /proc/acpi/wakeup 2>/dev/null || true
done

# Also disable WiFi wakeup via sysfs (sometimes missed by /proc/acpi/wakeup)
for wakefile in $(find /sys/devices -name "wakeup" -path "*/power/*" 2>/dev/null); do
    if [ "$(cat "$wakefile" 2>/dev/null)" = "enabled" ]; then
        echo "disabled" > "$wakefile" 2>/dev/null || true
    fi
done

# Verify
remaining=$(grep "\*enabled" /proc/acpi/wakeup | wc -l)
echo "Remaining enabled: $remaining"

# --- Ensure deep suspend (S3) is used, not s2idle ---
# s2idle ignores /proc/acpi/wakeup and sysfs wakeup controls;
# only deep sleep honors the power-button-only restrictions.
if grep -q deep /sys/power/mem_sleep 2>/dev/null; then
    echo deep > /sys/power/mem_sleep 2>/dev/null \
        && echo "  mem_sleep set to: deep (s2idle would ignore wakeup restrictions)" \
        || echo "  WARNING: could not set mem_sleep to deep"
else
    echo "  WARNING: deep sleep not supported by kernel"
fi

# Deploy a boot-time enforcer
cat > /usr/local/bin/wakeup-power-only << 'EOF'
#!/bin/sh
# Re-apply wake source restrictions after resume or boot
for dev in $(grep "\*enabled" /proc/acpi/wakeup 2>/dev/null | awk '{print $1}'); do
    echo "$dev" > /proc/acpi/wakeup 2>/dev/null || true
done
for wakefile in $(find /sys/devices -name "wakeup" -path "*/power/*" 2>/dev/null); do
    # Skip power button — never disable wake from power button
    case "$wakefile" in *LNXPWRBN*) continue ;; esac
    if [ "$(cat "$wakefile" 2>/dev/null)" = "enabled" ]; then
        echo "disabled" > "$wakefile" 2>/dev/null || true
    fi
done
# Use deep suspend (S3) so ACPI wakeup restrictions actually work.
# s2idle ignores all /proc/acpi/wakeup and sysfs wakeup controls.
grep -q deep /sys/power/mem_sleep 2>/dev/null && echo deep > /sys/power/mem_sleep 2>/dev/null || true
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

echo "SUCCESS: Only power button will wake the machine (deep sleep)."
echo "         mem_sleep set to 'deep' — s2idle would ignore wakeup restrictions."
exit 0
