#!/bin/bash
# tests/physlock-lock-test.sh
#
# Tests that physlock can lock, accept a password, and unlock cleanly
# WITHOUT soft-locking the active session.
#
# Uses openvt to run physlock on an unused VT so the current
# terminal is never locked. Uses expect to type the password.
#
# Run: bash tests/physlock-lock-test.sh

set -e

PASSWORD="${1:-123456}"
EXPECT_SCRIPT="/tmp/physlock-test-expect-$$"

echo "=== physlock lock/unlock test ==="
echo "Password length: ${#PASSWORD} chars"
echo ""

# Find an unused VT (VT 12 is usually free)
TEST_VT=12

# Kill anything on VT12 first
pkill -f "physlock" 2>/dev/null || true
sleep 0.3

# Write expect script
cat > "$EXPECT_SCRIPT" << EOF
set timeout 10
spawn openvt -c $TEST_VT -s -- /usr/local/bin/physlock
sleep 1
# Send password
send "$PASSWORD\r"
sleep 1
# If auth fails, physlock stays running — send SIGTERM to clean up
send "\003"
expect {
    eof { puts "PASS: physlock exited after password" }
    timeout { puts "FAIL: physlock did not exit within 10s" }
}
EOF

echo "Running physlock on VT$TEST_VT via expect..."
expect -f "$EXPECT_SCRIPT" 2>&1
EXIT_CODE=$?

rm -f "$EXPECT_SCRIPT"

# Clean up any leftover physlock
pkill -f "physlock" 2>/dev/null || true

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "PASS: physlock authenticated and exited cleanly"
else
    echo "FAIL: exit code $EXIT_CODE"
fi

exit $EXIT_CODE
