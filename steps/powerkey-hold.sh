#!/bin/bash
# steps/powerkey-hold.sh - THE POWER BUTTON MUST BE HELD (2.5 s) TO SHUT DOWN
#
# Problem: elogind acts on the power button *press* event (HandlePowerKey=poweroff),
# so a tap with the lid, a cable or a sleeve powers the machine off. Holding the
# button for a moment is the normal laptop gesture, and the embedded controller's
# own hard power-off already works that way.
#
# What this installs:
#   * /usr/local/bin/powerkey-hold — reads every input device that can report
#     KEY_POWER and measures the hold time from press to release, WHILE held:
#         release < 2.5 s  -> nothing at all (the accidental tap case)
#         held    2.5 s    -> /sbin/shutdown -h now: the Linux-based, orderly
#                              path (services stop, filesystems sync + unmount)
#         held    ~5 s     -> the embedded controller cuts the power itself.
#                              That is the hardware/system fallback and needs
#                              no software support - keep holding and it happens.
#   * /etc/elogind/logind.conf.d/20-powerkey.conf with HandlePowerKey=ignore,
#     because otherwise elogind powers off on the press and the daemon never
#     gets to measure anything.
#   * a start line in /etc/rc.d/rc.local (setsid, so rc.local exiting cannot
#     SIGHUP it away) logging to /var/log/<user>-powerkey.log.
#
# Idempotent: rebuilds only when the source changed, rewrites the drop-in only
# when it differs, adds the rc.local line only when absent, and does not start a
# second instance (the daemon holds a flock on /run/powerkey-hold.pid).
#
# Usage:
#   REPO_DIR=$PWD bash steps/powerkey-hold.sh          # install + start
#   REPO_DIR=$PWD bash steps/powerkey-hold.sh remove   # back to logind default
#
# Stage 1 fires WHILE held, not on release:
#   -t 2.5 -> /sbin/shutdown -h now   (orderly: services stop, fs sync+unmount)
#             2.5 s is the requested gesture; the bar counts up to it and says
#             so ("Power button: 1.2 s / 2.5 s = SHUTDOWN"). It still leaves
#             ~2.5 s of the EC's ~5 s hard-off window for the orderly path.
#   -T 0   -> disabled: beyond ~5 s the embedded controller force-cuts power
#             itself (measured), so a software force-off stage is pointless
#             (it used to be -T 10 and could never fire before the hard cut).
# Anything shorter than 2.5 s does nothing. The daemon ignores SIGTERM/SIGINT
# so it survives the shutdown it started and keeps measuring.
# Change the times with ARGS below (e.g. ARGS="-t 2 -T 8").

REPO_DIR="${REPO_DIR:-/root/Development/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

ACTION="${1:-install}"
SRC="$REPO_DIR/sources/powerkey-hold/powerkey-hold.c"
BUILD=/var/cache/powerkey-hold
DEST=/usr/local/bin/powerkey-hold
STARTSRC="$REPO_DIR/scripts/powerkey-hold-start"
STARTDEST=/usr/local/bin/powerkey-hold-start
DROPIN=/etc/elogind/logind.conf.d/20-powerkey.conf
RCLOCAL=/etc/rc.d/rc.local
LOGF="/var/log/${USER:-root}-powerkey.log"
# The hold times live in scripts/powerkey-hold-start (one place only, shared
# by rc.local and dwm-start); read back here so the summary cannot drift.
ARGS=$(sed -n 's/^ARGS="\(.*\)"$/\1/p' "$STARTSRC" 2>/dev/null)
[ -n "$ARGS" ] || ARGS="(see $STARTDEST)"

echo "*****************************************************"
echo "POWER BUTTON — $ACTION"
echo "*****************************************************"

ok=true
note() { echo "  $*"; }

running_pid() {
    local pid
    local pf=/run/powerkey-hold.pid
    [ -r "$pf" ] || return 1
    pid=$(cat "$pf" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q -- "$DEST" || return 1
    echo "$pid"
}

if [ "$ACTION" = "remove" ]; then
    if p=$(running_pid); then
        kill "$p" 2>/dev/null && note "stopped powerkey-hold (pid $p)"
    fi
    rm -f /run/powerkey-hold.pid
    if [ -f "$RCLOCAL" ] && grep -q 'powerkey-hold' "$RCLOCAL" 2>/dev/null; then
        grep -v 'powerkey-hold' "$RCLOCAL" > "$RCLOCAL.new" && mv "$RCLOCAL.new" "$RCLOCAL"
        chmod 755 "$RCLOCAL"   # the mv above would leave it 0644 (rc.M skips it)
        note "removed the rc.local start line"
    fi
    rm -f "$DROPIN" && note "removed $DROPIN"
    # restore acpid's original behaviour too
    if [ -f /etc/acpi/acpi_handler.sh.orig ]; then
        cp -a /etc/acpi/acpi_handler.sh.orig /etc/acpi/acpi_handler.sh \
            && note "restored /etc/acpi/acpi_handler.sh from .orig"
        /etc/rc.d/rc.acpid restart >/dev/null 2>&1 || true
    fi
    rm -f "$DEST" && note "removed $DEST"
    rm -f "$STARTDEST" && note "removed $STARTDEST"
    /etc/rc.d/rc.elogind restart >/dev/null 2>&1 || true
    note "logind handles the power button again (instant press = poweroff)"
    echo "SUCCESS: power button restored to logind behaviour."
    exit 0
fi

# --- 1. build ---------------------------------------------------------------
[ -f "$SRC" ] || { echo "ERROR: $SRC missing"; exit 1; }
mkdir -p "$BUILD"
if [ -f "$DEST" ] && [ "$DEST" -nt "$SRC" ]; then
    note "$DEST already newer than the source"
else
    if gcc -O2 -Wall -Wextra -o "$BUILD/powerkey-hold" "$SRC"; then
        install -Dm 755 "$BUILD/powerkey-hold" "$DEST" && note "built + installed $DEST"
    else
        echo "ERROR: build failed"; exit 1
    fi
fi
# --- 1a. the start helper ----------------------------------------------------
# rc.local and dwm-start both call this ONE file, so the hold times exist in
# exactly one place and a mistyped copy cannot desynchronise them.
if [ -f "$STARTSRC" ]; then
    if [ -f "$STARTDEST" ] && cmp -s "$STARTSRC" "$STARTDEST"; then
        note "$STARTDEST already up to date"
    else
        install -Dm 755 "$STARTSRC" "$STARTDEST" && note "installed $STARTDEST ($ARGS)"
    fi
else
    echo "ERROR: $STARTSRC missing"; exit 1
fi


# --- 1b. the "Shutting Down Now..." notice -----------------------------------
# Shown the instant the hold threshold is reached, i.e. BEFORE the shutdown
# command is spawned: a console line in the same style as the messages
# dwm-start.sh drops when X ends, plus the same text in the dwm bar (the only
# thing on screen while X is still up). Installed from scripts/ unchanged.
MSGSRC="$REPO_DIR/scripts/powerkey-shutdown-msg"
MSGDEST=/usr/local/bin/powerkey-shutdown-msg
if [ -f "$MSGSRC" ]; then
    if [ -f "$MSGDEST" ] && cmp -s "$MSGSRC" "$MSGDEST"; then
        note "$MSGDEST already up to date"
    else
        install -Dm 755 "$MSGSRC" "$MSGDEST" && note "installed $MSGDEST"
    fi
else
    note "WARNING: $MSGSRC missing — no on-screen shutdown notice"
fi

# --- 2. elogind must stop acting on the press -------------------------------
mkdir -p /etc/elogind/logind.conf.d
want='# Power button is handled by powerkey-hold: hold 2.5 s = orderly shutdown,
# a longer hold (~5 s) is cut by the embedded controller, tap = nothing.
# logind must NOT act on the press event, or an accidental tap powers off.
[Login]
HandlePowerKey=ignore'
if [ -f "$DROPIN" ] && [ "$(cat "$DROPIN")" = "$want" ]; then
    note "$DROPIN already correct"
else
    printf '%s\n' "$want" > "$DROPIN"
    note "wrote $DROPIN (HandlePowerKey=ignore)"
    # Restarting elogind can terminate the current graphical session, so it is
    # NOT done by default: the drop-in is read fresh at boot, and the machine
    # has to reboot to pick up the new kernel anyway. Force it if you want the
    # change to apply right now: RESTART_ELOGIND=1 bash steps/powerkey-hold.sh
    if [ "${RESTART_ELOGIND:-0}" = "1" ]; then
        /etc/rc.d/rc.elogind restart >/dev/null 2>&1 && note "elogind restarted" \
            || note "WARNING: could not restart elogind"
    else
        note "elogind NOT restarted (would end this session) — applies at next boot"
    fi
fi

# --- 2b. acpid is the OTHER instant-poweroff path ---------------------------
# Slackware's /etc/acpi/acpi_handler.sh has `power) /sbin/init 0`: acpid powers
# off on the ACPI power event by itself, regardless of elogind. That is why a
# tap still killed the machine even with HandlePowerKey=ignore (measured
# 2026-11-09: the daemon never logged the press, so another handler won).
ACPI_HANDLER=/etc/acpi/acpi_handler.sh
if [ -f "$ACPI_HANDLER" ]; then
    if grep -q '^[[:space:]]*power) /sbin/init 0' "$ACPI_HANDLER"; then
        [ -f "$ACPI_HANDLER.orig" ] || cp -a "$ACPI_HANDLER" "$ACPI_HANDLER.orig"
        sed -i 's|^\([[:space:]]*\)power) /sbin/init 0|\1power) :   # powerkey-hold decides (hold 2.5 s); a tap must not power off|' "$ACPI_HANDLER"
        note "acpid power handler neutralised in $ACPI_HANDLER (backup: .orig)"
        if [ -x /etc/rc.d/rc.acpid ]; then
            /etc/rc.d/rc.acpid restart >/dev/null 2>&1 && note "acpid reloaded" \
                || note "WARNING: could not restart acpid"
        fi
    else
        note "acpid power handler already neutralised"
    fi
else
    note "no $ACPI_HANDLER (acpid not installed?)"
fi

# --- 3. start it at boot ----------------------------------------------------
# rc.M runs /etc/rc.d/rc.local ONLY `if [ -x ... ]`, and Slackware ships that
# file 0644 — so every hook appended to it (this one included) was silently
# dead at boot: the hold count vanished from the bar after the next reboot.
# The mode is restored AFTER the rewrite below: `grep > file.new && mv` gives
# the replacement the umask mode (0644), which silently un-fixed the file.
if [ -f "$RCLOCAL" ]; then
    # ONE line, calling the helper; older `setsid ... -t ... powerkey-hold`
    # lines from previous versions are dropped so no stale times survive.
    if grep -q 'powerkey-hold' "$RCLOCAL" 2>/dev/null; then
        grep -v 'powerkey-hold' "$RCLOCAL" > "$RCLOCAL.new" && mv "$RCLOCAL.new" "$RCLOCAL"
        note "dropped the old powerkey-hold line(s) from rc.local"
    fi
    printf '%s\n' "$STARTDEST" >> "$RCLOCAL"
    note "rc.local start line: $STARTDEST"
    if [ -x "$RCLOCAL" ]; then
        note "$RCLOCAL is executable (rc.M runs it)"
    else
        if chmod 755 "$RCLOCAL"; then
            note "chmod +x $RCLOCAL (rc.M was skipping it: not executable)"
        else
            note "WARNING: could not chmod +x $RCLOCAL — nothing in it runs at boot"
            ok=false
        fi
    fi
else
    note "WARNING: $RCLOCAL not found — daemon will not start at boot"
    ok=false
fi

# --- 4. start now -----------------------------------------------------------
# A running instance keeps the CODE it was started with, so if the binary on
# disk is newer than the process, restart it — otherwise a rebuild would sit
# unused until the next boot. The daemon ignores SIGTERM on purpose (it must
# survive the shutdown it starts), so SIGKILL is the only way out; the new
# instance is started immediately below, and a hold inside that millisecond
# window does nothing at all, which is the safe failure.
if p=$(running_pid); then
    if [ "$DEST" -nt "/proc/$p" ]; then
        kill -KILL "$p" 2>/dev/null \
            && note "binary changed — restarted the running instance (pid $p)"
        rm -f /run/powerkey-hold.pid
        sleep 0.2
    fi
fi
if p=$(running_pid); then
    note "already running:"
    ps -o pid=,etime=,args= -p "$p" | sed 's/^/    /'
else
    # The helper carries the times and does the setsid; the step never spells
    # them out, so there is one definition only.
    "$STARTDEST"
    sleep 1
    if p=$(running_pid); then
        note "started:"
        ps -o pid=,etime=,args= -p "$p" | sed 's/^/    /'
    else
        note "ERROR: not running after start attempt"
        ok=false
    fi
fi

# --- 5. show the facts ------------------------------------------------------
note "stage 1     : $ARGS (from $STARTDEST) -> /sbin/shutdown -h now at the -t value"
note "stage 2     : disabled (-T 0); hardware EC force-off ~5 s covers it"
note "tap         : anything shorter than the -t value is ignored"
note "short tap   : ignored completely (after the next boot, when elogind reads HandlePowerKey=ignore)"
note "log         : $LOGF"
[ -f "$LOGF" ] && tail -2 "$LOGF" | sed 's/^/    /'
note "devices     : $(grep -o 'watching [0-9]* device(s) \[[^]]*\]' "$LOGF" 2>/dev/null | tail -1)"

if $ok; then
    echo "SUCCESS: power button: a 2.5 s hold starts an orderly shutdown; a longer hold is cut by the EC; taps do nothing."
    exit 0
else
    echo "ERROR: power button setup incomplete (see messages above)."
    exit 1
fi
