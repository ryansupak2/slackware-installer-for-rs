#!/bin/bash
# steps/session-cleanup.sh — NOWHERE FOR A SESSION TO HIDE
#
# Policy (decided 2026-11-14): when a login session ends nothing of that
# session survives. The only thing that lives on is the system connection
# itself (NetworkManager/wifi). VPN, audio, VOX dictation, bars, clipboard
# helpers — all stop.
#
# Two layers, because either one alone has a hole:
#
#   1. /usr/local/bin/session-stop (scripts/session-stop)
#      Session-scoped teardown by elogind cgroup:
#        session-stop            stop every process in THIS session's cgroup
#                                (called from dwm-start's EXIT trap)
#        session-stop --stale    start-of-session sweep of leftovers from
#                                sessions that died hard and so never ran
#                                their cleanup (called by dwm-start before the
#                                audio check)
#      This one also names the per-user daemons (voxd first, so it exits
#      through its handler and CLOSES its ALSA handle) and verifies that no
#      process of the user is left holding /dev/snd/pcm*.
#
#   2. /etc/elogind/logind.conf.d/30-kill-user-processes.conf
#      KillUserProcesses=yes — elogind terminates the session cgroup itself,
#      so even a session whose scripts never run (X crash, SIGKILL, power
#      loss of the compositor) leaves nothing behind.
#
# Why: measured 2026-11-14 — rs's voxd outlived rs's X session, kept
# /dev/snd/pcmC0D4c open, and WirePlumber then declared card 0 "unavailable
# (Device or resource busy)" for the NEXT session, which got "Dummy Output"
# only: no sound at all until the stale daemon was stopped.
#
# Idempotent: files are only rewritten when their content changed.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "SESSION CLEANUP (nothing survives a logout)"
echo "*****************************************************"

ok=true

# ── 1. session-stop helper ───────────────────────────────────────────
SRC="$REPO_DIR/scripts/session-stop"
DST=/usr/local/bin/session-stop

if [ ! -f "$SRC" ]; then
    echo "ERROR: $SRC missing."
    exit 1
fi

if [ -f "$DST" ] && cmp -s "$SRC" "$DST"; then
    echo "  $DST already up to date"
else
    install -m 755 "$SRC" "$DST" && echo "  $DST installed" || ok=false
fi

if [ -x "$DST" ]; then
    # dry run proves the helper parses and can see this session/cgroup
    if "$DST" --dry-run --stale >/dev/null 2>&1; then
        echo "  session-stop --dry-run --stale: ok"
    else
        echo "WARNING: session-stop --dry-run returned non-zero (see below)"
        "$DST" --dry-run --stale || true
    fi
else
    echo "ERROR: $DST is not executable."
    ok=false
fi

# ── 2. elogind: kill the session cgroup on logout ────────────────────
DROPIN_DIR=/etc/elogind/logind.conf.d
DROPIN="$DROPIN_DIR/30-kill-user-processes.conf"
TMP=$(mktemp)
cat >"$TMP" <<'EOF'
# KillUserProcesses (steps/session-cleanup.sh)
#
# When a session ends, elogind terminates the processes in that session's
# cgroup. That is the backstop for the session scripts: if X dies so hard that
# dwm-start's EXIT trap never runs, nothing of the session is left running.
#
# Why this machine needs it: a per-user daemon that outlives its session can
# keep hardware busy and break the NEXT session. Measured 2026-11-14: a stale
# voxd held /dev/snd/pcmC0D4c, WirePlumber declared card 0 "unavailable
# (Device or resource busy)", and the new session had only "Dummy Output" —
# no sound — until that process was stopped by hand.
#
# Policy is deliberately "nothing survives the session": the only thing that
# stays is the system-level connection (NetworkManager/wifi). Note the
# consequence documented in logind.conf(5): a terminal multiplexer such as
# tmux or screen started INSIDE the session dies with it (those tools need
# `systemd-run --scope`-style detachment to survive, which is exactly what we
# do not want here). VPN, audio, VOX and the status bars are session things
# and are torn down by /usr/local/bin/session-stop even before this fires.
#
# elogind reads this file at startup: it takes effect on the next boot (or the
# next elogind restart, which would end the running session).
[Login]
KillUserProcesses=yes
EOF

mkdir -p "$DROPIN_DIR"
if [ -f "$DROPIN" ] && cmp -s "$TMP" "$DROPIN"; then
    rm -f "$TMP"
    echo "  $DROPIN already up to date"
else
    if install -m 644 "$TMP" "$DROPIN"; then
        rm -f "$TMP"
        echo "  $DROPIN installed (KillUserProcesses=yes; active from next boot)"
    else
        rm -f "$TMP"
        ok=false
    fi
fi

# ── 3. dwm-start must actually call it ───────────────────────────────
# The cleanup function existed but was never invoked (no trap): a logout left
# every session daemon running. Assert the deployed launcher has the trap, so
# a stale /usr/local/bin/dwm-start cannot silently undo this policy.
if [ -f /usr/local/bin/dwm-start ]; then
    if grep -q 'trap cleanup EXIT' /usr/local/bin/dwm-start; then
        echo "  /usr/local/bin/dwm-start runs the cleanup trap"
    else
        echo "WARNING: /usr/local/bin/dwm-start has no cleanup trap — run steps/suckless-dwm.sh"
    fi
    if grep -q 'session-stop' /usr/local/bin/dwm-start; then
        echo "  /usr/local/bin/dwm-start calls session-stop"
    else
        echo "WARNING: /usr/local/bin/dwm-start does not call session-stop — run steps/suckless-dwm.sh"
    fi
else
    echo "  (no /usr/local/bin/dwm-start yet — steps/suckless-dwm.sh deploys it)"
fi

if $ok; then
    echo "SUCCESS: session teardown installed (session-stop + KillUserProcesses=yes)."
    exit 0
else
    echo "ERROR: session cleanup setup encountered errors."
    exit 1
fi
