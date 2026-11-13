#!/bin/bash
# tests/powerkey-shutdown-msg-test.sh
#
# Proves the "Shutting Down Now..." notice that powerkey-hold drops at the
# moment the 2.5 s power-button hold threshold is reached (scripts/
# powerkey-shutdown-msg), and that its text is IDENTICAL everywhere it shows
# up. Nothing here touches the real console, the real X display, the real
# terminals or a real FIFO consumer:
#
#   * terminals  — `broadcast "Shutting Down Now..."`, exactly the mechanism
#                  Mod+Shift+Q uses for "Exiting Window Manager Now...";
#   * console VT — the same words, undecorated, so it is waiting on the VT when
#                  X lets go (same place as dwm-start's exit messages);
#   * topbar     — the same words again through the session's temp-message
#                  files (dwm-status prints them verbatim) plus xsetroot, and
#                  "show all <seconds>" so hide mode keeps the bar revealed.
#
# It also checks the daemon side: the notice is fired BEFORE /sbin/shutdown,
# the 0.1 s running count exists and is TOPBAR-ONLY (no console/broadcast), and
# the count is cleared on release / stopped when the shutdown starts.
#
# Run: bash tests/powerkey-shutdown-msg-test.sh

set -u

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
HELPER="$REPO_DIR/scripts/powerkey-shutdown-msg"
DAEMON="$REPO_DIR/sources/powerkey-hold/powerkey-hold.c"
STEP="$REPO_DIR/steps/powerkey-hold.sh"
for f in "$HELPER" "$DAEMON" "$STEP"; do
    [ -f "$f" ] || { echo "FATAL: $f not found"; exit 1; }
done

NOTE="Shutting Down Now..."
WORK=$(mktemp -d /tmp/pkmsg-test-XXXXXX) || exit 1
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Stubs: record exactly what they were given.
cat > "$WORK/bin/xsetroot" <<'STUB'
#!/bin/sh
printf '%s|%s|%s\n' "$DISPLAY" "$XAUTHORITY" "$*" >> "$XSETROOT_CALLS"
exit 0
STUB
cat > "$WORK/bin/broadcast" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$BROADCAST_CALLS"
exit 0
STUB
chmod +x "$WORK/bin/xsetroot" "$WORK/bin/broadcast"

PASS=0
FAIL=0
check() {   # $1 description, $2 expected, $3 actual
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"
        PASS=$((PASS + 1))
    else
        printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1))
    fi
}
check_has() {   # $1 description, $2 literal, $3 haystack
    case "$3" in
        *"$2"*) check "$1" "yes" "yes" ;;
        *)      check "$1" "yes" "no" ;;
    esac
}

setup() {
    rm -rf "$WORK/run" "$WORK/console" "$WORK/xsetroot.calls" \
           "$WORK/broadcast.calls" "$WORK/fifo.out"
    mkdir -p "$WORK/run"
    mkfifo "$WORK/run/dwmbar-0"
    : > "$WORK/xsetroot.calls"
    : > "$WORK/broadcast.calls"
    export XSETROOT_CALLS="$WORK/xsetroot.calls"
    export BROADCAST_CALLS="$WORK/broadcast.calls"
}

# Run the helper with a reader attached to the FIFO, as dwm would be.
run_helper() {
    ( cat "$WORK/run/dwmbar-0" > "$WORK/fifo.out" 2>/dev/null ) &
    reader=$!
    CONSOLE="$WORK/console" XDG_RUNTIME_DIR="$WORK/run" \
        PATH="$WORK/bin:/usr/bin:/bin" timeout 10 sh "$HELPER" >"$WORK/stdout" 2>&1
    rc=$?
    wait "$reader" 2>/dev/null || true
    return $rc
}

echo "*****************************************************"
echo "POWER BUTTON SHUTDOWN NOTICE (\"$NOTE\")"
echo "*****************************************************"
echo "helper: $HELPER"
echo ""

# ------------------------------------------------------------------
echo "1. One message, identical in every channel"
setup
run_helper
check "exits 0 promptly" 0 "$?"

console_msg=$(sed -n 2p "$WORK/console" 2>/dev/null)
bar_msg=$(cat "$WORK/run/status_msg" 2>/dev/null)
broadcast_msg=$(sed -n 1p "$WORK/broadcast.calls" 2>/dev/null)
xsetroot_msg=$(awk -F'|' '{sub(/^-name /, "", $3); print $3}' "$WORK/xsetroot.calls" 2>/dev/null)

check "console text"        "$NOTE" "$console_msg"
check "topbar text"         "$NOTE" "$bar_msg"
check "broadcast text"      "$NOTE" "$broadcast_msg"
check "xsetroot text"       "$NOTE" "$xsetroot_msg"
check "console == topbar"   "$console_msg" "$bar_msg"
check "console == broadcast" "$console_msg" "$broadcast_msg"

# The console line is bare: no timestamp or [component] prefix may creep in,
# or it stops being the same message as the bar/terminal one.
check "console line has no decoration" "$NOTE" "$(printf '%s' "$console_msg" | sed 's/^\[[^]]*\] //')"
check "exactly one console line (plus its leading blank)" 2 "$(grep -c '' "$WORK/console")"

# ------------------------------------------------------------------
echo ""
echo "2. Every terminal is reached the same way Mod+Shift+Q does it"
check "broadcast was called once" 1 "$(awk 'END{print NR+0}' "$WORK/broadcast.calls")"

# ------------------------------------------------------------------
echo ""
echo "3. The topbar mechanism"
check_has "xsetroot saw DISPLAY=:0"           ":0|" "$(cat "$WORK/xsetroot.calls")"
check_has "xsetroot saw root's cookie"        "/root/.Xauthority|" "$(cat "$WORK/xsetroot.calls")"
end=$(cat "$WORK/run/status_end" 2>/dev/null)
case "$end" in
    ''|*[!0-9]*) check "status_end is a future timestamp" "yes" "no ($end)" ;;
    *)           check "status_end is a future timestamp" "yes" \
                     "$([ "$end" -gt "$(date +%s)" ] && echo yes || echo no)" ;;
esac
fifo=$(cat "$WORK/fifo.out" 2>/dev/null)
check_has "the FIFO tells hide mode to show the bar" "show all" "$fifo"
secs=$(printf '%s' "$fifo" | awk '{print $3}')
case "$secs" in
    ''|*[!0-9]*) check "the reveal lasts minutes, not 3 s" "yes" "no ($fifo)" ;;
    *)           check "the reveal lasts minutes (>60 s)" "yes" \
                     "$([ "$secs" -gt 60 ] && echo yes || echo no)" ;;
esac

# ------------------------------------------------------------------
echo ""
echo "4. Nothing blocks"
setup
CONSOLE="$WORK/console" XDG_RUNTIME_DIR="$WORK/run" \
    PATH="$WORK/bin:/usr/bin:/bin" timeout 5 sh "$HELPER" >/dev/null 2>&1
check "exits 0 with an unread FIFO" 0 "$?"
check_has "console still written" "Shutting Down Now..." "$(cat "$WORK/console")"

# ------------------------------------------------------------------
echo ""
echo "5. Degrades quietly"
setup
rm -rf "$WORK/run"
CONSOLE="$WORK/console" XDG_RUNTIME_DIR="$WORK/run" \
    PATH="$WORK/bin:/usr/bin:/bin" timeout 5 sh "$HELPER" >/dev/null 2>&1
check "exits 0 without a runtime dir" 0 "$?"
check_has "console line still written" "$NOTE" "$(cat "$WORK/console")"

setup
CONSOLE="$WORK/console" XDG_RUNTIME_DIR="$WORK/run" \
    PATH="/usr/bin:/bin" timeout 5 sh "$HELPER" >/dev/null 2>&1
check "exits 0 without xsetroot/broadcast" 0 "$?"
check "temp msg still written (dwm-status shows it)" "$NOTE" \
    "$(cat "$WORK/run/status_msg" 2>/dev/null)"

setup
CONSOLE=/nonexistent/console XDG_RUNTIME_DIR="$WORK/run" \
    PATH="$WORK/bin:/usr/bin:/bin" timeout 5 sh "$HELPER" >/dev/null 2>&1
check "exits 0 with an unwritable console" 0 "$?"
check "the bar notice was still written" "$NOTE" \
    "$(cat "$WORK/run/status_msg" 2>/dev/null)"

# ------------------------------------------------------------------
echo ""
echo "6. Daemon: the notice fires BEFORE the shutdown command"
block=$(awk '/else if \(!shutdown_done && held >= shutdown_s\)/ { f = 1 }
             f && /^\t\t}$/ { print; exit }
             f { print }' "$DAEMON")
[ -n "$block" ] || { echo "FATAL: could not extract the shutdown branch"; exit 1; }
check_has "the helper is called"       "powerkey-shutdown-msg" "$block"
check_has "the shutdown still happens" "/sbin/shutdown"        "$block"
msg_line=$(printf '%s\n' "$block" | grep -n 'run("/usr/local/bin/powerkey-shutdown-msg"' | cut -d: -f1)
sd_line=$(printf '%s\n' "$block" | grep -n 'run("/sbin/shutdown"' | cut -d: -f1)
check "the notice is spawned first" "yes" \
    "$([ -n "$msg_line" ] && [ -n "$sd_line" ] && [ "$msg_line" -lt "$sd_line" ] && echo yes || echo no)"

# ------------------------------------------------------------------
echo ""
echo "7. Daemon: the running hold count is 0.1 s and TOPBAR-ONLY"
check_has "the count starts 100 ms after the press" \
    "notice_next = pressed_at + 100.0;" "$(cat "$DAEMON")"
check_has "it steps every 100 ms while held" \
    "notice_next = now_ms() + 100.0;" "$(cat "$DAEMON")"
check_has "the count reads the elapsed hold" \
    '"Power button: %.1f s / %.1f s = SHUTDOWN"' "$(cat "$DAEMON")"
check_has "it goes through the bar temp-message files" \
    "/status_msg" "$(cat "$DAEMON")"
check "the daemon never touches the console" 0 "$(grep -c '/dev/console' "$DAEMON")"
check "the daemon never broadcasts"          0 "$(grep -c 'broadcast "' "$DAEMON")"
check_has "release before the threshold clears the count" \
    "notice_clear();" "$(cat "$DAEMON")"
check "the count stops when the shutdown starts" "yes" \
    "$(grep -c 'notice_on = 0;' "$DAEMON" | awk '{print ($1 >= 2) ? "yes" : "no"}')"

# ------------------------------------------------------------------
echo ""
echo "8. The step installs the helper"
check_has "the step knows the source" "scripts/powerkey-shutdown-msg" "$(cat "$STEP")"
check_has "the step installs it"      "powerkey-shutdown-msg"         "$(cat "$STEP")"

# ------------------------------------------------------------------
echo ""
echo "9. Fan-out: the notice reaches every live desktop session"
# One root-started helper must reach the bar of whichever user is at the
# screen (e.g. rs at /run/user/4877), not just root's. POWERKEY_SESSION_ROOT
# points the scan at a scratch tree so no live session is touched.
rm -rf "$WORK/sessions"
mkdir -p "$WORK/sessions/0" "$WORK/sessions/1000"
mkfifo "$WORK/sessions/1000/dwmbar-0"
: > "$WORK/xsetroot.calls"
: > "$WORK/broadcast.calls"
( cat "$WORK/sessions/1000/dwmbar-0" > "$WORK/fifo2.out" 2>/dev/null ) &
reader=$!
CONSOLE="$WORK/console2" XDG_RUNTIME_DIR="$WORK/sessions/0" \
    POWERKEY_SESSION_ROOT="$WORK/sessions" \
    PATH="$WORK/bin:/usr/bin:/bin" timeout 10 sh "$HELPER" >/dev/null 2>&1
rc=$?
wait "$reader" 2>/dev/null || true
check "exits 0" 0 "$rc"
check "own session bar"        "$NOTE" "$(cat "$WORK/sessions/0/status_msg" 2>/dev/null)"
check "other user's session bar" "$NOTE" "$(cat "$WORK/sessions/1000/status_msg" 2>/dev/null)"
check "other user's reveal"     "show all 600" "$(sed -n 1p "$WORK/fifo2.out" 2>/dev/null)"
check "console still written"   "$NOTE" "$(sed -n 2p "$WORK/console2" 2>/dev/null)"

echo "*****************************************************"
echo "RESULT: $PASS passed, $FAIL failed"
echo "*****************************************************"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
