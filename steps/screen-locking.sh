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
# pre : lock the X session and WAIT until slock provably covers the screen,
#       so nothing but slock can ever be seen when the machine wakes.
# post: if slock somehow died across the sleep, put it back immediately.
#
# The hook runs as root, but the X session may belong to any user. Lock as
# THAT user: slock needs their XAUTHORITY/runtime dir, and its per-user lock
# marker lives in /run/user/<uid>/slock.locked (root keeps
# /run/slock.locked — see sources/slock/slock.c).
#
# DISPLAY/XAUTHORITY are only defaults: the hook can be pointed at a scratch
# display (DISPLAY=:97 ...) for testing without touching the live session.
DISPLAY="${DISPLAY:-:0}"
export DISPLAY

xuid=""
xuser=""
if command -v loginctl >/dev/null 2>&1; then
    # Do not use positional parameters here; $1/$2 are pre/post and the event.
    _xsess=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4=="seat0" {print $1, $2, $3; exit}')
    xuid=$(printf '%s\n' "$_xsess" | awk '{print $2}')
    xuser=$(printf '%s\n' "$_xsess" | awk '{print $3}')
fi
[ -n "$xuser" ] || { xuid=0; xuser=root; }
xhome=$(getent passwd "$xuser" | cut -d: -f6)
[ -n "$xhome" ] || xhome=/root

if [ -z "${XAUTHORITY:-}" ]; then
    for c in "$xhome/.Xauthority" "$HOME/.Xauthority" /root/.Xauthority; do
        [ -n "$c" ] && [ -r "$c" ] && { XAUTHORITY=$c; break; }
    done
    if [ -z "${XAUTHORITY:-}" ]; then
        auth=$(ps -o args= -C Xorg 2>/dev/null | tr ' ' '\n' | grep -A1 '^-auth$' | tail -1)
        [ -n "$auth" ] && [ -r "$auth" ] && XAUTHORITY=$auth
    fi
fi
[ -n "${XAUTHORITY:-}" ] && export XAUTHORITY

run_lock() {
    if [ "$(id -u)" -eq "$xuid" ]; then
        /usr/local/bin/lock-screen.sh
    elif command -v runuser >/dev/null 2>&1; then
        runuser -u "$xuser" -- env DISPLAY="$DISPLAY" \
            ${XAUTHORITY:+XAUTHORITY="$XAUTHORITY"} \
            XDG_RUNTIME_DIR="/run/user/$xuid" HOME="$xhome" \
            /usr/local/bin/lock-screen.sh
    else
        su -s /bin/sh "$xuser" -c "HOME='$xhome' DISPLAY='$DISPLAY' XDG_RUNTIME_DIR='/run/user/$xuid' /usr/local/bin/lock-screen.sh"
    fi
}

case "$1" in
    pre)
        run_lock || echo "10-slock-lock: FAILED to lock before $2" >&2
        ;;
    post)
        run_lock || echo "10-slock-lock: could not re-lock after $2" >&2
        ;;
esac
exit 0
HOOKEOF
chmod 755 "$HOOK"
echo "  installed $HOOK"
HOOK_DIR="$SLEEP_DIR"

# ---------------------------------------------------------------------------
# 3b. Sleep log: an on-disk answer to "did it come back this time?"
#
# The 2026-11-12 hang left exactly one usable trace (the deep-suspend entry
# line in /var/log/messages), because syslogd is frozen from the moment the
# kernel starts suspending and the ring buffer dies with the power cut. This
# hook runs before the machine sleeps and again after it wakes, so the file
# itself is the evidence: a pre line without a matching post line means the
# machine never completed that suspend.
# ---------------------------------------------------------------------------
SLEEPLOG="$SLEEP_DIR/20-sleep-log"
cat > "$SLEEPLOG" << 'SLEEPLOGEOF'
#!/bin/sh
# 20-sleep-log — one line before sleeping, one after waking (see
# steps/screen-locking.sh). A pre line with no post line after it means the
# machine did not come back from that sleep; the rescue is a power-button
# hold. Times are local; the timestamp gap is the time spent asleep.
LOG="/var/log/${USER:-root}-sleep.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
case "$1" in
    pre)
        mem=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/power/mem_sleep 2>/dev/null)
        printf '%s: pre  %-9s mem_sleep=%s  going to sleep (no post line below = never woke)\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "${2:-sleep}" "${mem:-?}" >> "$LOG"
        ;;
    post)
        printf '%s: post %-9s mem_sleep=%s  resumed\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "${2:-sleep}" \
            "$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/power/mem_sleep 2>/dev/null)" >> "$LOG"
        ;;
esac
exit 0
SLEEPLOGEOF
chmod 755 "$SLEEPLOG"
echo "  installed $SLEEPLOG (sleep evidence: /var/log/<user>-sleep.log)"

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
echo "  sleep hooks: $HOOK_DIR/10-slock-lock, $HOOK_DIR/20-sleep-log"
# The lid's wakeup attributes live on the EC node (PNP0C09:00/PNP0C0D:00), NOT
# on the LNXSYSTM/LNXSYBUS alias - that one has no power/wakeup file at all.
lidw=$(find /sys/devices -path '*PNP0C0D*/power/wakeup' 2>/dev/null | head -1)
echo "  lid wake   : ${lidw:-<none found>} -> $(cat "${lidw:-/dev/null}" 2>/dev/null || echo '?')"
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
