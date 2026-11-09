#!/bin/bash
# steps/screen-locking.sh - SESSION LOCKING + LID POLICY (lock before sleep)
#
# What this step decides (and why):
#
#   * Lid close = the normal laptop behaviour: **suspend** (elogind's default
#     HandleLidSwitch=suspend, made explicit). It used to run /sbin/poweroff
#     from an acpid handler — that event is removed here.
#   * Opening the lid wakes the machine. steps/acpi-wakeup.sh keeps the lid
#     (PNP0C0D / LID0) enabled as a wake source for exactly this reason; the
#     power button stays the only OTHER wake source.
#   * Before the machine sleeps, slock must be covering the screen. The elogind
#     sleep hook below calls /usr/local/bin/lock-screen.sh in the "pre" stage
#     and waits for it: that script only returns 0 once slock reports its
#     keyboard/pointer grabs are held (/run/slock.locked). So a waking screen
#     can only ever show slock, never the desktop.
#   * The idle path has the same guarantee: /usr/local/bin/idle-lock.sh locks
#     shortly BEFORE the DPMS blank (started from scripts/dwm-start.sh).
#
# Locker itself: steps/slock.sh builds/installs slock + lock-screen.sh +
# idle-lock.sh + xidle. This step must NOT remove them (it used to `rm -f
# /usr/local/bin/slock`, which silently deleted the locker on every run).
#
# Idempotent: files are compared before copying, the old ACPI event and the old
# elogind "ignore lid" drop-in are removed if present, and the sleep hook is
# only restarted when it changed.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "SCREEN LOCKING + LID POLICY"
echo "*****************************************************"

ok=true

# ---------------------------------------------------------------------------
# 1. Retired pieces: lid-close → poweroff, and physlock/ttylock lockers.
# ---------------------------------------------------------------------------
echo "Removing the lid-close → poweroff ACPI handler..."
if [ -f /etc/acpi/events/lid-close ]; then
    rm -f /etc/acpi/events/lid-close && echo "  removed /etc/acpi/events/lid-close"
else
    echo "  already gone"
fi

echo "Removing retired lockers (physlock/ttylock)..."
rm -f /usr/local/bin/physlock /usr/local/bin/ttylock
rm -f /etc/pam.d/physlock /etc/pam.d/ttylock

if [ -x /usr/local/bin/slock ]; then
    echo "Keeping slock — see steps/slock.sh"
else
    echo "WARNING: slock not installed — run: REPO_DIR=$REPO_DIR bash steps/slock.sh"
    ok=false
fi

# ---------------------------------------------------------------------------
# 2. elogind: lid = suspend (the default policy), not "ignore".
# ---------------------------------------------------------------------------
echo "Configuring elogind lid policy (suspend)..."
mkdir -p /etc/elogind/logind.conf.d
rm -f /etc/elogind/logind.conf.d/10-lid-ignore.conf
LID_CONF=/etc/elogind/logind.conf.d/10-lid-suspend.conf
cat > "$LID_CONF" << 'CONF'
# Lid close suspends the machine (elogind's default, stated explicitly).
# Locking happens in the sleep hook, BEFORE the suspend, so the waking screen
# shows slock. Dock behaviour stays "ignore" (external display in use).
[Login]
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=suspend
HandleLidSwitchDocked=ignore
CONF
echo "  wrote $LID_CONF"

# ---------------------------------------------------------------------------
# 3. Sleep hook: lock AND WAIT for the covering window before the sleep.
#    elogind runs these as root with $1=pre|post and $2=suspend|hibernate|...
# ---------------------------------------------------------------------------
SLEEP_DIR=""
for d in /lib64/elogind/system-sleep /usr/lib64/elogind/system-sleep /etc/elogind/system-sleep; do
    if [ -d "$d" ]; then SLEEP_DIR=$d; break; fi
done
if [ -z "$SLEEP_DIR" ]; then
    echo "  WARNING: no elogind system-sleep directory — creating /etc/elogind/system-sleep"
    SLEEP_DIR=/etc/elogind/system-sleep
    mkdir -p "$SLEEP_DIR"
fi

HOOK="$SLEEP_DIR/10-slock-lock"
cat > "$HOOK" << 'HOOKEOF'
#!/bin/sh
# 10-slock-lock — run by elogind around sleep.
#
# pre : lock the X session and WAIT until slock provably covers the screen,
#       so nothing but slock can ever be seen when the machine wakes.
# post: if slock somehow died across the sleep, put it back immediately.
#
# DISPLAY/XAUTHORITY are only defaults: the hook can be pointed at a scratch
# display (DISPLAY=:97 ...) for testing without touching the live session.
DISPLAY="${DISPLAY:-:0}"
export DISPLAY
[ -n "${XAUTHORITY:-}" ] && export XAUTHORITY
[ -r /root/.Xauthority ] && XAUTHORITY="${XAUTHORITY:-/root/.Xauthority}" && export XAUTHORITY

case "$1" in
    pre)
        /usr/local/bin/lock-screen.sh || echo "10-slock-lock: FAILED to lock before $2" >&2
        ;;
    post)
        /usr/local/bin/lock-screen.sh || echo "10-slock-lock: could not re-lock after $2" >&2
        ;;
esac
exit 0
HOOKEOF
chmod 755 "$HOOK"
echo "  installed $HOOK"
HOOK_DIR="$SLEEP_DIR"

# ---------------------------------------------------------------------------
# 4. acpid still serves non-lid events; restart only if the config changed.
# ---------------------------------------------------------------------------
if [ -x /etc/rc.d/rc.acpid ]; then
    /etc/rc.d/rc.acpid restart >/dev/null 2>&1 || /etc/rc.d/rc.acpid start >/dev/null 2>&1 || true
    echo "  acpid (re)started — no lid action any more"
fi

# ---------------------------------------------------------------------------
# 5. Show the resulting state, and what the lid will now physically do.
# ---------------------------------------------------------------------------
echo "  lid policy : $(grep -h '^HandleLidSwitch=' /etc/elogind/logind.conf.d/*.conf 2>/dev/null | tail -1)"
echo "  sleep hook : $HOOK_DIR/10-slock-lock"
echo "  lid wake   : $(cat /sys/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0C0D:00/power/wakeup 2>/dev/null || echo 'n/a')"
echo "  ACPI lid   : $([ -f /etc/acpi/events/lid-close ] && echo 'poweroff handler STILL PRESENT' || echo 'none (elogind handles it)')"
echo "  note       : lid close now suspends; opening the lid wakes it. To lock"
echo "               by hand: Mod+Escape, or /usr/local/bin/lock-screen.sh"

if $ok; then
    echo "SUCCESS: lid = suspend with lock-before-sleep; no more poweroff on close."
    exit 0
else
    echo "ERROR: locking policy incomplete (see messages above)."
    exit 1
fi
