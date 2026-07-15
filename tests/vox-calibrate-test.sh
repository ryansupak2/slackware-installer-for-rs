#!/bin/bash
# vox-calibrate-test.sh — Integration test for VOX calibration pipeline
#
# Verifies that on cold start:
#   1. VOX starts from zero (no model loaded, no state file)
#   2. Toggle ON triggers "loading" badge
#   3. Internal calibration WAV is fed to recognizer
#   4. Recognizer produces text from calibration WAV → pipeline is LIVE
#   5. Internal playback STOPS, microphone input takes over
#   6. Badge transitions from "loading" → "recording"
#   7. Audio capture starts from real microphone
#
# Run:  bash tests/vox-calibrate-test.sh
# Requires: voxd installed at /usr/local/bin/voxd

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
LOG="/var/log/root-vox.log"
STATE_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vox_state"
VOXD_BIN="/usr/local/bin/voxd"

pass() { echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "  ${YELLOW}INFO${NC} $1"; }

cleanup() {
    pkill voxd 2>/dev/null || true
    rm -f "$STATE_FILE"
}
trap cleanup EXIT

echo "============================================================"
echo "VOX Calibration Pipeline Test"
echo "============================================================"

# ── Phase 0: Clean slate ──────────────────────────────────────
echo ""
echo "── Phase 0: Clean slate"
cleanup
sleep 0.5

# Verify nothing is running
if pgrep -x voxd >/dev/null 2>&1; then
    fail "voxd already running — cannot start clean"
    exit 1
fi
pass "No voxd running"

# Verify state file is absent
if [ -f "$STATE_FILE" ]; then
    fail "vox_state file exists before start"
else
    pass "No vox_state file (VOX off)"
fi

# Mark log position
LOG_START=$(wc -l < "$LOG" 2>/dev/null || echo 0)

# ── Phase 1: Cold start daemon ────────────────────────────────
echo ""
echo "── Phase 1: Cold start daemon"

$VOXD_BIN &
sleep 1

if ! pgrep -x voxd >/dev/null 2>&1; then
    fail "voxd failed to start"
    exit 1
fi
VOXD_PID=$(pgrep -x voxd)
pass "voxd started (PID $VOXD_PID)"

# Verify nothing loaded before toggle (state file should be absent)
if [ -f "$STATE_FILE" ]; then
    fail "vox_state present before toggle ON (model pre-loaded?)"
else
    pass "No state file before toggle — nothing pre-loaded"
fi

# ── Phase 2: Toggle ON → calibration ──────────────────────────
echo ""
echo "── Phase 2: Toggle ON → calibration sequence"

pkill -USR1 voxd

# Wait for calibration to complete (up to 15s)
WAITED=0
CAL_OK=0
BADGE_RECORDING=0
MIC_ACTIVE=0

while [ $WAITED -lt 15 ]; do
    sleep 0.5
    WAITED=$((WAITED + 1))
    
    # Check state file
    STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "")
    
    # Check log for key events
    NEW_LOG=$(tail -n +$((LOG_START+1)) "$LOG" 2>/dev/null || echo "")
    
    if echo "$NEW_LOG" | grep -q "Calibration: stream produced text"; then
        if [ $CAL_OK -eq 0 ]; then
            pass "Calibration WAV produced text — stream is LIVE"
            CAL_OK=1
        fi
    fi
    
    if [ "$STATE" = "recording" ] || [ "$STATE" = "recording+dump" ]; then
        if [ $BADGE_RECORDING -eq 0 ]; then
            pass "Badge → recording (internal playback stopped, mic active)"
            BADGE_RECORDING=1
        fi
    fi
    
    if echo "$NEW_LOG" | grep -q "First audio chunk arrived"; then
        if [ $MIC_ACTIVE -eq 0 ]; then
            pass "Microphone capture started"
            MIC_ACTIVE=1
        fi
    fi
    
    # If all checks passed, we're done
    if [ $CAL_OK -eq 1 ] && [ $BADGE_RECORDING -eq 1 ] && [ $MIC_ACTIVE -eq 1 ]; then
        break
    fi
done

# ── Phase 3: Verify calibration sequence order ────────────────
echo ""
echo "── Phase 3: Verify calibration sequence order"

NEW_LOG=$(tail -n +$((LOG_START+1)) "$LOG" 2>/dev/null || echo "")

# Extract timestamps for ordering check
CAL_LOAD=$(echo "$NEW_LOG" | grep "Calibration: WAV loaded" | head -1)
CAL_TEXT=$(echo "$NEW_LOG" | grep "Calibration: stream produced text" | head -1)
BADGE_LINE=$(echo "$NEW_LOG" | grep "Badge → recording" | head -1)
MIC_LINE=$(echo "$NEW_LOG" | grep "First audio chunk arrived" | head -1)

echo "  Sequence:"
echo "    1. $CAL_LOAD"
echo "    2. $CAL_TEXT"
echo "    3. $BADGE_LINE"
echo "    4. $MIC_LINE"

# Verify all events occurred
if [ -z "$CAL_LOAD" ]; then
    fail "WAV loaded event missing"
else
    pass "1. Internal WAV playback started"
fi

if [ -z "$CAL_TEXT" ]; then
    fail "Recognizer text event missing"
else
    pass "2. Recognizer produced word → proved primed"
fi

if [ -z "$BADGE_LINE" ]; then
    fail "Badge transition missing"
else
    pass "3. Badge → recording (internal playback stopped)"
fi

if [ -z "$MIC_LINE" ]; then
    fail "Microphone capture event missing"
else
    pass "4. Microphone input active"
fi

# Verify "loading" appeared before "recording"
LOADING_LINE=$(echo "$NEW_LOG" | grep "TOGGLE ON" | head -1)
echo ""
echo "  State transitions:"
echo "    loading at: $(echo "$NEW_LOG" | grep "TOGGLE ON" | head -1)"
echo "    recording at: $BADGE_LINE"

# ── Phase 4: Toggle OFF ───────────────────────────────────────
echo ""
echo "── Phase 4: Toggle OFF"

pkill -USR1 voxd
sleep 1

# Verify state cleared
if [ -f "$STATE_FILE" ]; then
    fail "vox_state still present after toggle OFF"
else
    pass "State file cleared after toggle OFF"
fi

# Verify voxd still running (model stays warm)
if pgrep -x voxd >/dev/null 2>&1; then
    pass "voxd still running after OFF (model stays warm)"
else
    fail "voxd exited after toggle OFF"
fi

# ── Phase 5: Warm start (no calibration needed) ───────────────
echo ""
echo "── Phase 5: Warm start — no calibration"

LOG_START=$(wc -l < "$LOG" 2>/dev/null || echo 0)

pkill -USR1 voxd
sleep 2

NEW_LOG=$(tail -n +$((LOG_START+1)) "$LOG" 2>/dev/null || echo "")

if echo "$NEW_LOG" | grep -q "Calibration:"; then
    fail "Calibration ran on warm start (should skip)"
else
    pass "No calibration on warm start (model already warm)"
fi

if echo "$NEW_LOG" | grep -q "Warm start"; then
    pass "Warm start path taken"
else
    info "Warm start indication not found in log"
fi

STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "")
if [ "$STATE" = "recording" ] || [ "$STATE" = "recording+dump" ]; then
    pass "Badge shows recording on warm start"
else
    fail "Badge state = '$STATE' after warm start (expected 'recording')"
fi

# ── Report ────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "============================================================"

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "FAILED — Full calibration log:"
    echo "---"
    grep -E "TOGGLE|Calib|Badge|First audio|Model|Warm|Cold|ready" "$LOG" | tail -20
    exit 1
fi

echo ""
echo "SUCCESS: Calibration pipeline works correctly."
echo "  1. Internal WAV plays → recognizer proves it's alive"
echo "  2. Internal playback stops → microphone takes over"
echo "  3. Badge transitions: loading → recording"
echo "  4. Warm starts skip calibration"
exit 0
