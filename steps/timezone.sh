#!/bin/bash
# steps/timezone.sh — TIMEZONE + NTP CONFIGURATION
#
# Sets system timezone from TZ variable in setup.keys.root (default: America/Chicago).
# Enables chronyd (NTP) to always sync time from the internet.
# Ensures NTP starts at boot.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "TIMEZONE + NTP CONFIGURATION"
echo "*****************************************************"

ok=true

# Source keys if available
if [ -f "$REPO_DIR/setup.keys.root" ]; then
    . "$REPO_DIR/setup.keys.root" 2>/dev/null || true
fi

TZ="${TZ:-America/Chicago}"
echo "Timezone: $TZ"

# ── Set timezone ────────────────────────────────────────────────
if [ -f "/usr/share/zoneinfo/$TZ" ]; then
    if timedatectl set-timezone "$TZ" 2>/dev/null; then
        echo "  Timezone set to $TZ"
    else
        ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime 2>/dev/null || ok=false
        echo "  Timezone set to $TZ (via symlink)"
    fi
else
    echo "ERROR: timezone $TZ not found in /usr/share/zoneinfo/"
    ok=false
fi

# ── Ensure NTP servers are configured ─────────────────────────
echo "Configuring NTP servers..."
NTP_CONF=/etc/ntp.conf
if [ -f "$NTP_CONF" ]; then
    # If only local clock is configured (no external servers), add pool servers
    if ! grep -qE '^(server|pool)[[:space:]]+[^1]' "$NTP_CONF" 2>/dev/null; then
        echo "  Adding NTP pool servers to $NTP_CONF"
        cat >> "$NTP_CONF" << 'NTPEOF'

# NTP pool servers (added by installer)
pool 0.pool.ntp.org iburst
pool 1.pool.ntp.org iburst
pool 2.pool.ntp.org iburst
pool 3.pool.ntp.org iburst
NTPEOF
        echo "  NTP pool servers added"
    else
        echo "  External NTP servers already configured"
    fi
else
    echo "  WARNING: $NTP_CONF not found"
fi

# ── Enable NTP at boot ────────────────────────────────────────
echo "Enabling NTP at boot..."
if [ -f /etc/rc.d/rc.ntpd ]; then
    chmod +x /etc/rc.d/rc.ntpd 2>/dev/null || true
    echo "  rc.ntpd enabled for boot"
else
    echo "  WARNING: /etc/rc.d/rc.ntpd not found"
fi

# ── Force-sync time now ────────────────────────────────────────
echo "Syncing time from internet..."
# Stop ntpd so ntpdate can use the NTP socket
pkill -x ntpd 2>/dev/null || true
sleep 1
if command -v ntpdate >/dev/null 2>&1; then
    if ntpdate -b pool.ntp.org 2>/dev/null; then
        echo "  Time synced from pool.ntp.org"
    else
        echo "  WARNING: ntpdate sync failed (no internet?)"
    fi
else
    echo "  WARNING: ntpdate not found"
fi
# Restart ntpd
/etc/rc.d/rc.ntpd start 2>/dev/null || ntpd -gq 2>/dev/null || true
sleep 1
if pgrep -x ntpd >/dev/null 2>&1; then
    echo "  ntpd restarted"
elif pgrep -x chronyd >/dev/null 2>&1; then
    echo "  chronyd running"
else
    echo "  WARNING: NTP daemon not running"
fi

# ── Sync hardware clock to system clock ──────────────────────────
if command -v hwclock >/dev/null 2>&1; then
    hwclock --systohc 2>/dev/null && echo "  Hardware clock synced"
fi

echo ""
echo "Current time: $(date '+%Y-%m-%d %H:%M:%S %Z')"

if $ok; then
    echo "SUCCESS: Timezone set to $TZ, NTP enabled."
    exit 0
else
    echo "ERROR: Timezone configuration failed."
    exit 1
fi
