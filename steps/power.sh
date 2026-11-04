#!/bin/bash
# steps/power.sh - POWER / BATTERY POLICY (the `power` tool + auto AC/battery mode)
#
# Idempotent. Installs:
#   /usr/local/bin/power                       CLI: status / set / profile / auto / wake
#   /var/lib/power/state                       persistent policy state (never clobbered)
#   /etc/default/cpufreq                       governor=powersave at boot
#   /etc/udev/rules.d/95-power-policy.rules    `power apply` on AC plug/unplug
#   /etc/sudoers.d/power                       wheel can change settings without password
#   /lib64/elogind/system-sleep/power.sh       `power boot` after resume
#   /etc/rc.d/rc.local hook                    `power boot` at boot (guarded append)
#
# Survives reboot (rc.local + rc.cpufreq + udev) and X exit (dwm-start runs
# `power boot` and applies the blank/DPMS timeout from state on every session).

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "POWER / BATTERY POLICY                               "
echo "*****************************************************"

ok=true
STATE_DIR="/var/lib/power"
STATE_FILE="$STATE_DIR/state"

# --- 1. The tool itself -------------------------------------------------
echo "Installing power tool..."
if cp "$REPO_DIR/scripts/power.sh" /usr/local/bin/power; then
    chmod 755 /usr/local/bin/power
    echo "  Copied scripts/power.sh -> /usr/local/bin/power"
else
    echo "ERROR: failed to install /usr/local/bin/power"
    ok=false
fi

# --- 2. State (defaults installed once, never overwritten) -------------
echo "Installing policy state..."
mkdir -p "$STATE_DIR" || ok=false
if [ -f "$STATE_FILE" ]; then
    echo "  Keeping existing $STATE_FILE"
else
    if cp "$REPO_DIR/dotfiles/power/state.default" "$STATE_FILE"; then
        chmod 644 "$STATE_FILE"
        echo "  Created $STATE_FILE (defaults: auto=on battery=balanced ac=performance)"
    else
        echo "ERROR: failed to create $STATE_FILE"
        ok=false
    fi
fi

# --- 3. Boot-time governor default (Slackware rc.cpufreq) --------------
echo "Setting boot governor default (rc.cpufreq)..."
if cp "$REPO_DIR/dotfiles/power/cpufreq" /etc/default/cpufreq; then
    chmod 644 /etc/default/cpufreq
    echo "  /etc/default/cpufreq: SCALING_GOVERNOR=powersave"
else
    echo "ERROR: failed to write /etc/default/cpufreq"
    ok=false
fi

# --- 4. udev: re-apply on AC plug/unplug ------------------------------
echo "Installing udev rule for AC plug/unplug..."
if cp "$REPO_DIR/dotfiles/udev/95-power-policy.rules" /etc/udev/rules.d/; then
    chmod 644 /etc/udev/rules.d/95-power-policy.rules
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=power_supply 2>/dev/null || true
    echo "  /etc/udev/rules.d/95-power-policy.rules installed"
else
    echo "ERROR: failed to install udev rule"
    ok=false
fi

# --- 5. sudoers (wheel can run `power` without a password) ------------
echo "Installing sudoers entry..."
if mkdir -p /etc/sudoers.d && cp "$REPO_DIR/dotfiles/sudoers/power" /etc/sudoers.d/power; then
    chmod 440 /etc/sudoers.d/power
    if visudo -cf /etc/sudoers.d/power >/dev/null 2>&1; then
        echo "  /etc/sudoers.d/power installed"
    else
        echo "  WARNING: sudoers syntax check failed — removing to stay safe"
        rm -f /etc/sudoers.d/power
        ok=false
    fi
else
    echo "ERROR: failed to install sudoers entry"
    ok=false
fi

# --- 6. elogind post-resume hook ---------------------------------------
echo "Installing elogind post-resume hook..."
SLEEP_DIR="/lib64/elogind/system-sleep"
[ -d "$SLEEP_DIR" ] || SLEEP_DIR="/usr/lib/elogind/system-sleep"
if [ -d "$SLEEP_DIR" ]; then
    if cp "$REPO_DIR/dotfiles/power/elogind-post-resume.sh" "$SLEEP_DIR/power.sh"; then
        chmod 755 "$SLEEP_DIR/power.sh"
        echo "  $SLEEP_DIR/power.sh installed"
    else
        echo "ERROR: failed to install elogind hook"
        ok=false
    fi
else
    echo "  WARNING: elogind system-sleep dir not found — skipped resume hook"
fi

# --- 7. rc.local boot hook (guarded append, never duplicated) ---------
echo "Installing boot hook in /etc/rc.d/rc.local..."
if [ -f /etc/rc.d/rc.local ]; then
    if grep -q "/usr/local/bin/power boot" /etc/rc.d/rc.local 2>/dev/null; then
        echo "  Already present."
    else
        cat >> /etc/rc.d/rc.local << 'EOF'

# power: apply battery/AC policy + wake restrictions (installed by steps/power.sh)
/usr/local/bin/power boot
EOF
        echo "  Added '/usr/local/bin/power boot' to rc.local"
    fi
else
    echo "ERROR: /etc/rc.d/rc.local not found"
    ok=false
fi

# --- 8. Apply now -----------------------------------------------------
echo "Applying policy for the current power source..."
if /usr/local/bin/power apply; then
    echo "  Applied."
else
    echo "  WARNING: initial apply reported an error"
fi
if /usr/local/bin/power boot >/dev/null 2>&1; then
    echo "  Wake/suspend policy enforced (see: power wake)."
fi

if $ok; then
    echo ""
    echo "SUCCESS: power policy installed."
    echo "  check :  power            (or: power status / power wake)"
    echo "  change:  power profile powersave|balanced|performance"
    echo "           power auto on|off / power auto battery|ac <profile>"
    echo "           power set brightness 40 / power set blank 5 / power set turbo off"
    echo "  auto mode follows AC/battery via udev, reapplies at boot (rc.local) and after resume."
    exit 0
else
    echo "ERROR: power policy installation failed."
    exit 1
fi
