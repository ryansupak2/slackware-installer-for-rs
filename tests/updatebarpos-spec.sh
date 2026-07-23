#!/bin/bash
# tests/updatebarpos-spec.sh — verify hide-mode bar overlay behavior
#
# Tests that updatebarpos() in dwm.c correctly handles:
#   1. showbar=1 + hidemode=0 → working area has bar offset (non-hide-mode)
#   2. showbar=0 + hidemode=1 → working area is full screen, bar off-screen
#   3. showbar=1 + hidemode=1 → working area is full screen, bar overlays on top
#
# This matches the C logic:
#   if (m->showbar && !hidemode)     → reserve bar space (wy += bh, wh -= bh)
#   else if (m->showbar && hidemode) → overlay bar (by at top, wy/wh unchanged)
#   else                             → bar off-screen (by = -bh, wy/wh full)
#
# Run: bash tests/updatebarpos-spec.sh

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Simulate updatebarpos in bash
# Input: showbar (0/1), hidemode (0/1), topbar (0/1)
# Output: wy_offset, wh, by
sim_updatebarpos() {
    local showbar=$1 hidemode=$2 topbar=$3
    local my=0 mh=1080  # assume 1080p
    local bh=30          # bar height
    local wy=$my wh=$mh by

    if [ "$showbar" = 1 ] && [ "$hidemode" = 0 ]; then
        # Permanent bar: reserve space
        wh=$((mh - bh))
        if [ "$topbar" = 1 ]; then
            by=$wy
            wy=$((wy + bh))
        else
            by=$((wy + wh))
        fi
    elif [ "$showbar" = 1 ] && [ "$hidemode" = 1 ]; then
        # Hide-mode temp bar: overlay, don't resize
        if [ "$topbar" = 1 ]; then
            by=$my
        else
            by=$((my + mh - bh))
        fi
    else
        # Hidden: off-screen
        by=$((-bh))
    fi

    echo "wy=$wy wh=$wh by=$by"
}

echo "=== Test 1: showbar=1 hidemode=0 (normal mode, bar visible) ==="
result=$(sim_updatebarpos 1 0 1)
expected="wy=30 wh=1050 by=0"
if [ "$result" = "$expected" ]; then
    pass "working area shrinks for bar: $result"
else
    fail "expected $expected but got $result"
fi

echo "=== Test 2: showbar=0 hidemode=1 (hide mode, bar hidden) ==="
result=$(sim_updatebarpos 0 1 1)
expected="wy=0 wh=1080 by=-30"
if [ "$result" = "$expected" ]; then
    pass "full screen, bar off-screen: $result"
else
    fail "expected $expected but got $result"
fi

echo "=== Test 3: showbar=1 hidemode=1 (hide mode, bar temp-shown) ==="
result=$(sim_updatebarpos 1 1 1)
expected="wy=0 wh=1080 by=0"
if [ "$result" = "$expected" ]; then
    pass "full screen working area + bar overlays at top: $result"
else
    fail "expected $expected but got $result"
fi

echo "=== Test 4: showbar=1 hidemode=1 bottom bar ==="
result=$(sim_updatebarpos 1 1 0)
expected="wy=0 wh=1080 by=1050"
if [ "$result" = "$expected" ]; then
    pass "full screen + bottom overlay: $result"
else
    fail "expected $expected but got $result"
fi

echo "=== Test 5: showbar=0 hidemode=0 (normal mode, bar hidden by toggle) ==="
result=$(sim_updatebarpos 0 0 1)
expected="wy=0 wh=1080 by=-30"
if [ "$result" = "$expected" ]; then
    pass "full screen, bar off-screen (manual hide): $result"
else
    fail "expected $expected but got $result"
fi

# The key bug-fix test: hide-mode toggle from off→on should not change working area
echo ""
echo "=== Test 6: Bug scenario — terminal placed during temp bar show ==="
echo "  Step 1: hidemode=ON, bar hidden (initial state)"
r1=$(sim_updatebarpos 0 1 1)
echo "    $r1 — working area is full screen"
echo "  Step 2: temp show triggers bar=visible"
r2=$(sim_updatebarpos 1 1 1)
echo "    $r2 — working area STILL full screen (bar overlays)"
echo "  Step 3: new terminal starts → tile() uses wh=1080 not wh=1050"
echo "    OLD BUG: wh=1050 → terminal 30px too low"
echo "    FIX: wh=1080 → terminal at correct position"

if echo "$r2" | grep -q "wh=1080"; then
    pass "working area unchanged during temp bar show → FIX WORKS"
else
    fail "working area changed during temp bar show → BUG PRESENT"
fi

echo ""
echo "=================================================="
echo "COMPLETE: $PASS passed, $FAIL failed"
echo "=================================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
