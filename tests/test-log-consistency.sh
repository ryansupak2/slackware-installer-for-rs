#!/bin/bash
# tests/test-log-consistency.sh — verify unified log directory and script deployment
#
# Tests:
#  1. /var/log/sessions exists with 1777 permissions
#  2. All deployed scripts use LOG_DIR="/var/log/sessions"
#  3. No script has $HOME/logs fallback (old pattern removed)
#  4. Both root and non-root users can write to /var/log/sessions
#  5. Step is idempotent

set -euo pipefail
REPO_DIR="${REPO_DIR:-/root/Development/slackware-installer-for-rs}"
PASS=0
FAIL=0

check() {
    local desc="$1" cond="$2"
    if eval "$cond"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Test: Log Consistency ==="
echo ""

# ── Test 1: Directory exists with correct permissions ──────────────────
echo "── 1. /var/log/sessions ──"
check "directory exists"                        '[ -d /var/log/sessions ]'
check "permissions are 1777 (sticky, a+rwx)"    '[ "$(stat -c "%a" /var/log/sessions)" = "1777" ]'
check "owned by root"                           '[ "$(stat -c "%U" /var/log/sessions)" = "root" ]'

# ── Test 2: All deployed scripts point to /var/log/sessions ────────────
echo "── 2. Deployed scripts use /var/log/sessions ──"
BINS="dwm-start dwm-status dwl-start dwl-status net-watch vnc vpn wifi-manager vpn-suspend"
for bin in $BINS; do
    check "$bin uses LOG_DIR=/var/log/sessions" \
        "grep -q 'LOG_DIR=.*/var/log/sessions' /usr/local/bin/$bin 2>/dev/null"
done

# ── Test 3: No fallback to $HOME/logs remains ──────────────────────────
echo "── 3. No $HOME/logs fallback ──"
for bin in $BINS; do
    check "$bin has no HOME/logs fallback" \
        "! grep -q 'HOME/logs' /usr/local/bin/$bin 2>/dev/null"
done

# ── Test 4: Write access for multiple users ────────────────────────────
echo "── 4. Write access ──"
ROOT_TESTFILE="/var/log/sessions/.log-consistency-test-root-$$"
RS_TESTFILE="/var/log/sessions/.log-consistency-test-rs-$$"

# root can write
if echo "root-test" > "$ROOT_TESTFILE" 2>/dev/null; then
    check "root can write to /var/log/sessions" "true"
    rm -f "$ROOT_TESTFILE"
else
    check "root can write to /var/log/sessions" "false"
fi

# rs can write (if user exists)
if id rs >/dev/null 2>&1; then
    if su -s /bin/bash -c "echo rs-test > $RS_TESTFILE" rs 2>/dev/null; then
        check "user rs can write to /var/log/sessions" "true"
        rm -f "$RS_TESTFILE"
    else
        check "user rs can write to /var/log/sessions" "false"
    fi
else
    echo "  SKIP: user 'rs' does not exist"
fi

# Sticky bit: rs cannot delete root's file
echo "root-test" > "$ROOT_TESTFILE"
chmod 644 "$ROOT_TESTFILE"
if id rs >/dev/null 2>&1; then
    if su -s /bin/bash -c "rm -f $ROOT_TESTFILE" rs 2>/dev/null; then
        check "sticky bit: rs cannot delete root files" "false"
    else
        check "sticky bit: rs cannot delete root files" "true"
    fi
fi
rm -f "$ROOT_TESTFILE"

# ── Test 5: Step is idempotent ─────────────────────────────────────────
echo "── 5. Idempotent step ──"
STEP_OUTPUT=$(REPO_DIR="$REPO_DIR" bash "$REPO_DIR/steps/log-consistency.sh" 2>&1)
if echo "$STEP_OUTPUT" | grep -q "already exists"; then
    check "step detects existing /var/log/sessions" "true"
else
    check "step detects existing /var/log/sessions" "false"
fi

# ── Summary ────────────────────────────────────────────────────────────
echo ""
echo "========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "========================================="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
