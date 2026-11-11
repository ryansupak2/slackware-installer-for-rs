#!/bin/bash
# steps/powerkey-hold.sh - POWER BUTTON MUST BE HELD (3 s) TO SHUT DOWN
#
# Problem: elogind acts on the power button *press* event (HandlePowerKey=poweroff),
# so a tap with the lid, a cable or a sleeve powers the machine off. Holding the
# button for a few seconds is the normal laptop gesture, and the embedded
# controller's own hard power-off already works that way.
#
# What this installs:
#   * /usr/local/bin/powerkey-hold — reads the power button's event device and
#     measures the hold time from press to release:
#         release < 3 s  -> nothing at all (the accidental tap case)
#         release >= 3 s -> sync(2) then /sbin/poweroff (a CLEAN shutdown, and
#                           it fires before the EC's hard cut at ~5 s)
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
# Two stages, both fired WHILE held (not on release):
#   -t 1.5 -> /sbin/shutdown -h now   (orderly: services stop, fs sync+unmount)
#            1.5 s leaves ~3.5 s of the EC's ~5 s hard-off window for it.
#   -T 0   -> disabled: beyond ~5 s the embedded controller force-cuts power
#             itself (measured), so a software force-off stage is pointless
#             (it used to be -T 10 and could never fire before the hard cut).
# Shorter than 3 s does nothing. The daemon ignores SIGTERM so it survives the
# shutdown it started, which is what makes the 10 s stage reachable.
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
DROPIN=/etc/elogind/logind.conf.d/20-powerkey.conf
RCLOCAL=/etc/rc.d/rc.local
LOGF="/var/log/${USER:-root}-powerkey.log"
ARGS="-t 1.5 -T 0"

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

# --- 2. elogind must stop acting on the press -------------------------------
mkdir -p /etc/elogind/logind.conf.d
want='# Power button is handled by powerkey-hold: hold 3 s = orderly shutdown,
# hold 10 s = forced power off, tap = nothing. logind must NOT act on the
# press event, or an accidental tap powers off.
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
        sed -i 's|^\([[:space:]]*\)power) /sbin/init 0|\1power) :   # powerkey-hold decides (hold 3 s); a tap must not power off|' "$ACPI_HANDLER"
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
START_LINE="setsid $DEST $ARGS >>$LOGF 2>&1 &"
if [ -f "$RCLOCAL" ]; then
    if grep -q 'powerkey-hold' "$RCLOCAL" 2>/dev/null; then
        # NOTE: sed replacement is not literal - '&' means "the whole match"
        # and '|' is our delimiter, so both must be escaped ("2>&1" bit us once).
        escaped=$(printf '%s' "$START_LINE" | sed 's/[&|\\]/\\&/g')
        sed -i "s|^setsid .*powerkey-hold.*$|$escaped|" "$RCLOCAL"
        note "rc.local start line refreshed"
    else
        printf '%s\n' "$START_LINE" >> "$RCLOCAL"
        note "added start line to rc.local"
    fi
else
    note "WARNING: $RCLOCAL not found — daemon will not start at boot"
    ok=false
fi

# --- 4. start now -----------------------------------------------------------
if p=$(running_pid); then
    note "already running:"
    ps -o pid=,etime=,args= -p "$p" | sed 's/^/    /'
else
    setsid "$DEST" $ARGS >>"$LOGF" 2>&1 &
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
note "stage 1     : $ARGS  -> /sbin/shutdown -h now at the -t value"
note "stage 2     : disabled (-T 0); hardware EC force-off ~5 s covers it"
note "tap         : anything shorter than the -t value is ignored"
note "short tap   : ignored completely (after the next boot, when elogind reads HandlePowerKey=ignore)"
note "log         : $LOGF"
[ -f "$LOGF" ] && tail -2 "$LOGF" | sed 's/^/    /'
note "devices     : $(grep -o 'watching [0-9]* device(s) \[[^]]*\]' "$LOGF" 2>/dev/null | tail -1)"

if $ok; then
    echo "SUCCESS: power button: 1.5 s hold starts an orderly shutdown; longer is cut by the EC; taps do nothing."
    exit 0
else
    echo "ERROR: power button setup incomplete (see messages above)."
    exit 1
fi
