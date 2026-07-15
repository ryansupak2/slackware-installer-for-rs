#!/bin/bash
# steps/screen-locking.sh - SCREEN LOCKING (Slackware edition)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

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

# --- elogind system-sleep hook (lock screen before/after suspend) ---
ELG_DIR="/lib64/elogind/system-sleep"
if [ ! -d "$ELG_DIR" ]; then
    echo "ERROR: elogind system-sleep directory not found at $ELG_DIR."
    echo "       Screen will not lock on suspend/resume."
    ok=false
else
    mkdir -p "$ELG_DIR" 2>/dev/null || true
    cp "$REPO_DIR/dotfiles/lockscreen/elogind-sleep-hook.sh" "$ELG_DIR/lock-screen.sh" 2>/dev/null || ok=false
    chmod +x "$ELG_DIR/lock-screen.sh" 2>/dev/null || true
    echo "  elogind sleep hook deployed to $ELG_DIR/lock-screen.sh"
fi

# wlock (Wayland screen locker)
echo "Installing screen lockers (wlock + slock + physlock)..."

wlock_ok=false
if [ -x /usr/local/bin/wlock ] && [ -f /etc/pam.d/wlock ]; then
    echo "  wlock already installed — skipping build"
    wlock_ok=true
else
    echo "Building wlock (Wayland screen locker)..."
    echo "  Installing wlock build dependencies..."
    install_pkg "pam libxkbcommon pkg-config"

    if [ -d "$REPO_DIR/sources/wlock" ]; then
        if make -C "$REPO_DIR/sources/wlock"; then
            cp "$REPO_DIR/sources/wlock/wlock" /usr/local/bin/wlock 2>/dev/null
            echo "  wlock built and installed to /usr/local/bin/wlock."
            cp "$REPO_DIR/sources/wlock/wlock.pam" /etc/pam.d/wlock 2>/dev/null
            echo "  wlock PAM config installed."
            if grep -qE '^[[:space:]]*(auth|account)[[:space:]]+(required|requisite|sufficient)[[:space:]]+pam_unix\.so' /etc/pam.d/wlock 2>/dev/null; then
                wlock_ok=true
            else
                echo "ERROR: wlock PAM config missing required pam_unix.so entries."
                wlock_ok=false
            fi
        else
            echo "ERROR: could not build wlock (is wayland-base installed?)."
        fi
    fi
fi

# slock (X11 screen locker — colors match wlock)
slock_ok=false
if [ -x /usr/local/bin/slock ] && [ -f /etc/pam.d/slock ]; then
    echo "  slock already installed — skipping build"
    slock_ok=true
else
    echo "Building slock (X11 screen locker)..."
    echo "  Installing slock build dependencies..."
    install_pkg "libX11 pkg-config"

    if [ -d "$REPO_DIR/sources/slock" ]; then
        if make -C "$REPO_DIR/sources/slock"; then
            cp "$REPO_DIR/sources/slock/slock" /usr/local/bin/slock 2>/dev/null
            echo "  slock built and installed to /usr/local/bin/slock."
            cp "$REPO_DIR/sources/slock/slock.pam" /etc/pam.d/slock 2>/dev/null
            echo "  slock PAM config installed."
            if grep -qE '^[[:space:]]*(auth|account)[[:space:]]+(required|requisite|sufficient)[[:space:]]+pam_unix\.so' /etc/pam.d/slock 2>/dev/null; then
                slock_ok=true
            else
                echo "ERROR: slock PAM config missing required pam_unix.so entries."
                slock_ok=false
            fi
        else
            echo "ERROR: could not build slock (is X11 installed?)."
        fi
    fi
fi

# Verdict: acpid configs AND all three lockers must succeed — no fallbacks
if [ -x /usr/local/bin/lock-screen.sh ] && \
   [ -f /etc/acpi/events/lid-close ] && \
   [ -f /etc/acpi/events/lid-open ]; then
    if $wlock_ok && $physlock_ok && $slock_ok; then
        echo "SUCCESS: Screen locking fully configured (wlock + slock + physlock + acpid)."
        exit 0
    elif $wlock_ok && $physlock_ok && ! $slock_ok; then
        echo "WARNING: wlock and physlock installed but slock failed."
        echo "  X11 screen locking will fall back to physlock."
        exit 0
    elif $wlock_ok && ! $physlock_ok; then
        echo "ERROR: wlock installed but physlock failed."
        exit 1
    elif ! $wlock_ok && $physlock_ok; then
        echo "ERROR: physlock installed but wlock failed (run Core/wayland-base first)."
        exit 1
    else
        echo "ERROR: all lockers (wlock, slock, physlock) failed to install."
        exit 1
    fi
else
    echo "ERROR: could not configure screen locking."
    exit 1
fi
