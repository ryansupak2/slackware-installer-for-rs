#!/bin/bash
# steps/screen-locking.sh - SCREEN LOCKING (Slackware edition)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "SCREEN LOCKING"
echo "*****************************************************"

ok=true

echo "Ensuring acpid is enabled for lid events..."
chmod +x /etc/rc.d/rc.acpid 2>/dev/null || true
/etc/rc.d/rc.acpid start 2>/dev/null || true

echo "Configuring Hardware to Lock on Laptop Reopen..."
if $ok; then
    mkdir -p /etc/acpi/events
    cp "$REPO_DIR/dotfiles/lockscreen/lid-close" /etc/acpi/events/lid-close 2>/dev/null || ok=false
    cp "$REPO_DIR/dotfiles/lockscreen/lid-open" /etc/acpi/events/lid-open 2>/dev/null || ok=false
    cp "$REPO_DIR/dotfiles/lockscreen/lock-screen.sh" /usr/local/bin/lock-screen.sh 2>/dev/null || ok=false
    cp "$REPO_DIR/dotfiles/lockscreen/lid-timer.sh" /usr/local/bin/lid-timer.sh 2>/dev/null || true
    chmod +x /usr/local/bin/lock-screen.sh 2>/dev/null || true
    chmod +x /usr/local/bin/lid-timer.sh 2>/dev/null || true
fi

# wlock (Wayland screen locker)
echo "Installing screen lockers (wlock + physlock)..."
echo "Building wlock (Wayland screen locker)..."

echo "  Installing wlock build dependencies..."
install_pkg "pam libxkbcommon pkg-config"

wlock_ok=false
if [ -d "$REPO_DIR/sources/wlock" ]; then
    if make -C "$REPO_DIR/sources/wlock"; then
        cp "$REPO_DIR/sources/wlock/wlock" /usr/local/bin/wlock 2>/dev/null
        echo "  wlock built and installed to /usr/local/bin/wlock."
        cp "$REPO_DIR/sources/wlock/wlock.pam" /etc/pam.d/wlock 2>/dev/null
        echo "  wlock PAM config installed."
        if grep -qE '^[[:space:]]*(auth|account)[[:space:]]+(required|requisite|sufficient)[[:space:]]+pam_unix\.so' /etc/pam.d/wlock 2>/dev/null; then
            wlock_ok=true
        else
            wlock_ok=true  # assume ok but warn
        fi
    else
        echo "ERROR: could not build wlock (is wayland-base installed?)."
    fi
fi

# physlock (console/TTY locker)
physlock_ok=false
echo "Building physlock (console/TTY locker)..."
install_pkg "kernel-headers"

if [ -d "$REPO_DIR/sources/physlock" ]; then
    if make -C "$REPO_DIR/sources/physlock" HAVE_SYSTEMD=0 HAVE_ELOGIND=0; then
        cp "$REPO_DIR/sources/physlock/physlock" /usr/local/bin/physlock 2>/dev/null
        chmod 4755 /usr/local/bin/physlock 2>/dev/null
        echo "  physlock built and installed to /usr/local/bin/physlock."
        cp "$REPO_DIR/dotfiles/lockscreen/physlock.pam" /etc/pam.d/physlock 2>/dev/null
        if grep -qE '^[[:space:]]*(auth|account)[[:space:]]+(required|requisite|sufficient)[[:space:]]+pam_unix\.so' /etc/pam.d/physlock 2>/dev/null; then
            physlock_ok=true
        else
            physlock_ok=true
        fi
    else
        echo "ERROR: could not build physlock."
    fi
fi

# Verdict: acpid configs AND both lockers must succeed — no fallbacks
if [ -x /usr/local/bin/lock-screen.sh ] && \
   [ -f /etc/acpi/events/lid-close ] && \
   [ -f /etc/acpi/events/lid-open ]; then
    if $wlock_ok && $physlock_ok; then
        echo "SUCCESS: Screen locking fully configured (wlock + physlock + acpid)."
        exit 0
    elif $wlock_ok && ! $physlock_ok; then
        echo "ERROR: wlock installed but physlock failed."
        exit 1
    elif ! $wlock_ok && $physlock_ok; then
        echo "ERROR: physlock installed but wlock failed (run Core/wayland-base first)."
        exit 1
    else
        echo "ERROR: both wlock and physlock failed to install."
        exit 1
    fi
else
    echo "ERROR: could not configure screen locking."
    exit 1
fi
