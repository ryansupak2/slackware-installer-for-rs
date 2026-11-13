#!/bin/bash
# steps/user-helpers.sh - NARROW PASSWORDLESS SUDO FOR ONE DESKTOP USER
#
# The installed desktop tools call a handful of commands through `sudo -n`:
#
#   power             brightness / power profile / panel control (needs sysfs)
#   vpn               NordVPN: openvpn, kill switch (iptables/ip/pkill/sysctl)
#   slsk              /etc/rc.d/rc.slskd start|stop|restart|status
#
# Without these rules those features simply do not work for a non-root user,
# so "can use everything that is installed" requires them. They are scoped to
# the named user (NOT the wheel group) and to exactly those binaries — this is
# not sudo-all, and it grants no package management, no shell, no /etc edits.
#
# Idempotent: regenerates /etc/sudoers.d/50-user-<user>-helpers only when the
# rendered content changed, and validates with visudo before installing.
#
# Usage: TARGET_USER=rs REPO_DIR=... bash steps/user-helpers.sh

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
TARGET_USER="${TARGET_USER:-$1}"

if [ -z "$TARGET_USER" ]; then
    echo "ERROR: TARGET_USER not set for user-helpers.sh"
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: user-helpers.sh must run as root"
    exit 1
fi
case "$TARGET_USER" in
    *[!a-zA-Z0-9._-]*)
        echo "ERROR: invalid user name '$TARGET_USER'"
        exit 1
        ;;
esac

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "HELPER SUDO RULES: $TARGET_USER"
echo "*****************************************************"

id "$TARGET_USER" >/dev/null 2>&1 || {
    echo "ERROR: user $TARGET_USER does not exist (run steps/user-ensure.sh first)"
    exit 1
}

SUDOERS_DIR=/etc/sudoers.d
DEST="$SUDOERS_DIR/50-user-$TARGET_USER-helpers"
TMP="$(mktemp /tmp/sudoers-$TARGET_USER.XXXXXX)" || exit 1
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<EOF
# Managed by steps/user-helpers.sh — narrow passwordless helpers for $TARGET_USER.
# These are the only root operations the installed desktop tools use.

# power: brightness, AC/battery profile, panel blanking (writes sysfs)
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/local/bin/power
Defaults:$TARGET_USER env_keep += "POWER_ELEVATED POWER_INVOKER POWER_DISPLAY POWER_XAUTHORITY"

# vpn: NordVPN client + kill switch (same command set as dotfiles/sudoers/nordvpn)
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/local/bin/vpn, /usr/sbin/openvpn, /usr/bin/setsid, /usr/bin/chmod, /usr/bin/pkill, /sbin/sysctl, /usr/sbin/iptables, /usr/sbin/ip6tables, /sbin/ip, /usr/sbin/ip

# slsk: Soulseek daemon control (start/stop/restart/status only)
$TARGET_USER ALL=(ALL) NOPASSWD: /etc/rc.d/rc.slskd *

Defaults:$TARGET_USER !requiretty, lecture=never
EOF

chmod 0440 "$TMP"
if ! visudo -cqf "$TMP" >/dev/null 2>&1; then
    echo "ERROR: generated sudoers snippet is invalid:"
    visudo -cf "$TMP"
    exit 1
fi

if [ -f "$DEST" ] && cmp -s "$TMP" "$DEST"; then
    echo "  $DEST already up to date"
else
    install -Dm 0440 "$TMP" "$DEST"
    echo "  installed $DEST"
fi

echo "  granted (passwordless, $TARGET_USER only):"
echo "    power, vpn/openvpn + kill switch, slskd rc script"
echo "  NOT granted: package installs, shell, arbitrary commands, wheel"
echo "SUCCESS: helper sudo rules ensured for $TARGET_USER."
exit 0
