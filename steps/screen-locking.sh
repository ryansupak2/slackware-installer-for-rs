#!/bin/bash
# steps/screen-locking.sh - SCREEN LOCKING (Slackware edition)
# Uses physlock for everything — works identically for X11 and TTY.

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

echo "Deploying lock scripts and ACPI events..."

if $ok; then
    mkdir -p /etc/acpi/events

    # Lid close → lock-screen + lid-timer (both backgrounded)
    cp "$REPO_DIR/dotfiles/lockscreen/lid-close" /etc/acpi/events/lid-close 2>/dev/null || ok=false

    # Lid open → lock-screen (re-lock on resume)
    cp "$REPO_DIR/dotfiles/lockscreen/lid-open" /etc/acpi/events/lid-open 2>/dev/null || ok=false

    # lock-screen.sh — called from Mod+Esc, acpid, elogind hooks
    cp "$REPO_DIR/dotfiles/lockscreen/lock-screen.sh" /usr/local/bin/lock-screen.sh 2>/dev/null || ok=false
    chmod +x /usr/local/bin/lock-screen.sh 2>/dev/null || true

    # lid-timer.sh — waits 10s then suspends
    cp "$REPO_DIR/dotfiles/lockscreen/lid-timer.sh" /usr/local/bin/lid-timer.sh 2>/dev/null || ok=false
    chmod +x /usr/local/bin/lid-timer.sh 2>/dev/null || true

    # acpi_handler.sh — power button logs instead of shutting down
    cp "$REPO_DIR/dotfiles/lockscreen/acpi_handler.sh" /etc/acpi/acpi_handler.sh 2>/dev/null || true
    chmod +x /etc/acpi/acpi_handler.sh 2>/dev/null || true

    # elogind system-sleep hook — lock on any suspend
    ELG_DIR="/lib64/elogind/system-sleep"
    if [ -d "$ELG_DIR" ]; then
        cp "$REPO_DIR/dotfiles/lockscreen/elogind-sleep-hook.sh" "$ELG_DIR/lock-screen.sh" 2>/dev/null || true
        chmod +x "$ELG_DIR/lock-screen.sh" 2>/dev/null || true
    fi

    # Remove lock-and-suspend.sh (replaced by lid-timer.sh + lock-screen.sh)
    rm -f /usr/local/bin/lock-and-suspend.sh 2>/dev/null || true

    # Remove default ACPI event (catches everything, double-processes)
    rm -f /etc/acpi/events/default 2>/dev/null || true

    # Remove obsolete packages
    removepkg xlockmore 2>/dev/null || true
fi

echo "Installing lockers (slock for X11 + physlock for TTY/suspend)..."
slock_ok=true
physlock_ok=true

# --- slock (X11 screen locker — overlays X, no VT switch) ---
if [ -x /usr/local/bin/slock ] && [ -f /etc/pam.d/slock ] && \
       cmp -s "$REPO_DIR/sources/slock/slock.c" /usr/local/src/slock-stamp/slock.c 2>/dev/null; then
    echo "  slock already installed — skipping build"
else
    echo "Building slock..."
    install_pkg "libX11 pkg-config" 2>/dev/null || true
    if [ -d "$REPO_DIR/sources/slock" ]; then
        if make -C "$REPO_DIR/sources/slock" 2>&1; then
            cp "$REPO_DIR/sources/slock/slock" /usr/local/bin/slock
            cp "$REPO_DIR/sources/slock/slock.pam" /etc/pam.d/slock
            mkdir -p /usr/local/src/slock-stamp
            cp "$REPO_DIR/sources/slock/slock.c" /usr/local/src/slock-stamp/slock.c
            echo "  slock built and installed."
        else
            echo "ERROR: could not build slock."
            slock_ok=false
        fi
    fi
fi


# --- physlock (TTY screen locker — VT-based, survives suspend) ---
if [ -x /usr/local/bin/physlock ] && [ -f /etc/pam.d/physlock ] && \
       cmp -s "$REPO_DIR/sources/physlock/main.c" /usr/local/src/physlock-stamp/main.c 2>/dev/null; then
    echo "  physlock already installed — skipping build"
else
    echo "Building physlock..."
    if [ -d "$REPO_DIR/sources/physlock" ]; then
        if make -C "$REPO_DIR/sources/physlock" HAVE_SYSTEMD=0 HAVE_ELOGIND=1; then
            install -m 4755 -o root -g root \
                "$REPO_DIR/sources/physlock/physlock" /usr/local/bin/physlock 2>/dev/null
            echo "  physlock built and installed to /usr/local/bin/physlock."
            cp "$REPO_DIR/dotfiles/lockscreen/physlock.pam" /etc/pam.d/physlock 2>/dev/null
            echo "  physlock PAM config installed."
            # Stamp so we detect source changes on reinstall
            mkdir -p /usr/local/src/physlock-stamp
            cp "$REPO_DIR/sources/physlock/main.c" /usr/local/src/physlock-stamp/main.c
            if ! grep -qE '^[[:space:]]*(auth|account)[[:space:]]+(required|requisite|sufficient)[[:space:]]+pam_unix\.so' /etc/pam.d/physlock 2>/dev/null; then
                echo "ERROR: physlock PAM config missing required pam_unix.so entries."
                physlock_ok=false
            fi
        else
            echo "ERROR: could not build physlock."
            physlock_ok=false
        fi
    else
        echo "ERROR: physlock source not found at $REPO_DIR/sources/physlock."
        physlock_ok=false
    fi
fi

# Verdict
if [ -x /usr/local/bin/lock-screen.sh ] && \
   [ -x /usr/local/bin/lid-timer.sh ] && \
   [ -f /etc/acpi/events/lid-close ] && \
   [ -f /etc/acpi/events/lid-open ]; then
    if $slock_ok && $physlock_ok; then
        echo "SUCCESS: Screen locking configured (slock + physlock + acpid)."
        exit 0
    elif ! $slock_ok; then
        echo "ERROR: slock failed to install."
        exit 1
    else
        echo "ERROR: physlock failed to install."
        exit 1
    fi
else
    echo "ERROR: could not configure screen locking."
    exit 1
fi
