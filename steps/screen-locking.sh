#!/bin/bash
# steps/screen-locking.sh - lid-close → shutdown (idempotent)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"

echo "*****************************************************"
echo "SCREEN LOCKING"
echo "*****************************************************"

echo "Configuring lid-close to shut down..."
mkdir -p /etc/acpi/events
cp "$REPO_DIR/dotfiles/lockscreen/lid-close" /etc/acpi/events/lid-close

echo "Removing old lid-open event (not needed)..."
rm -f /etc/acpi/events/lid-open

echo "Removing old lock-screen.sh..."
rm -f /usr/local/bin/lock-screen.sh

# --- elogind: ignore lid switch (ACPI handles it via /sbin/poweroff) ---
echo "Configuring elogind to ignore lid switch..."
mkdir -p /etc/elogind/logind.conf.d
cp "$REPO_DIR/dotfiles/lockscreen/elogind-lid-ignore.conf" /etc/elogind/logind.conf.d/10-lid-ignore.conf

echo "Removing old elogind sleep hook..."
rm -f /lib64/elogind/system-sleep/lock-screen.sh

echo "Removing old lockers..."
rm -f /usr/local/bin/physlock /usr/local/bin/ttylock /usr/local/bin/slock
rm -f /etc/pam.d/physlock /etc/pam.d/ttylock /etc/pam.d/slock

echo "Restarting acpid..."
/etc/rc.d/rc.acpid restart 2>/dev/null || /etc/rc.d/rc.acpid start 2>/dev/null || true

echo "Restarting elogind..."
/etc/rc.d/rc.elogind restart 2>/dev/null || true

echo "SUCCESS: lid-close → shutdown configured"
exit 0
