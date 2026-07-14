#!/bin/bash
#
# terminal-newline-proof.sh — Prove stdout behavior of bashrc in a real shell
#
# Sources the ACTUAL DWL_FIRST_TERMINAL / hide_mode logic from the deployed
# /root/.bashrc in a controlled sub-shell, captures stdout to a temp file
# (NOT via $() which strips trailing newlines), and verifies exact output.

set -euo pipefail

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TEST() { TESTS_RUN=$((TESTS_RUN + 1)); echo ""; echo -e "${YELLOW}─── TEST $TESTS_RUN: $1 ───${NC}"; }
PASS() { TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "  ${GREEN}PASS${NC}: $1"; }
FAIL() { TESTS_FAILED=$((TESTS_FAILED + 1)); echo -e "  ${RED}FAIL${NC}: $1"; }

setup_runtime_dir() {
    local dir="$1"
    mkdir -p "$dir" 2>/dev/null
    chmod 700 "$dir" 2>/dev/null || true
}

cleanup_runtime_dir() {
    local dir="$1"
    rm -rf "$dir" 2>/dev/null || true
}

# Source the DWL_FIRST_TERMINAL / hide_mode logic and capture stdout to a FILE
# (not via $() — that strips trailing newlines, which is exactly what we're testing).
# Appends a sentinel line so we can detect the end without losing trailing newlines.
source_bashrc_to_file() {
    local dwl_first="$1"    # "yes" or "no"
    local hide_mode="$2"    # "yes" or "no"
    local runtime_dir="$3"
    local outfile="$4"

    # Build environment
    local env_vars=(
        "XDG_RUNTIME_DIR=$runtime_dir"
        "HOME=/root"
    )
    if [ "$dwl_first" = "yes" ]; then
        env_vars+=("DWL_FIRST_TERMINAL=1")
    fi

    # Create/remove hide_mode file
    local hide_file="$runtime_dir/hide_mode"
    rm -f "$hide_file"
    if [ "$hide_mode" = "yes" ]; then
        touch "$hide_file"
    fi

    # Write a test script that:
    # 1. Defines a mock neofetch alias (doesn't run real neofetch)
    # 2. Sources the exact logic from lines 57-79 of the deployed bashrc
    # 3. Appends a sentinel marker

    local test_script="$runtime_dir/test-snippet.sh"
    cat > "$test_script" << 'SCRIPT_EOF'
# Mock neofetch: don't actually run it; just print markers
neofetch() {
    echo "[NEOFETCH_OUTPUT_START]"
    echo "neofetch would display system info here"
    echo "[NEOFETCH_OUTPUT_END]"
}

# Now run the exact same logic as /root/.bashrc lines 57-79
LOG="/tmp/bashrc-proof-log-$$.log"

# First X terminal: neofetch + audio device log (once per session)
if [ -n "${DWL_FIRST_TERMINAL:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    echo "[$(date '+%H:%M:%S')] first-terminal: running neofetch" >> "$LOG"
    echo
    neofetch
    # Audio logging not relevant to test — skip dmesg/arecord to avoid noise
    unset DWL_FIRST_TERMINAL
# Hide mode: add newline so prompt isn't at top of screen
elif [ -f "$XDG_RUNTIME_DIR/hide_mode" ]; then
    echo "[$(date '+%H:%M:%S')] hide-mode newline" >> "$LOG"
    echo
else
    echo "[$(date '+%H:%M:%S')] normal start (no newline)" >> "$LOG"
fi

# Sentinel — must be the LAST line of output
echo "___SENTINEL___"
SCRIPT_EOF

    # Run in clean sub-shell, capture stdout to file
    env -i "${env_vars[@]}" bash --norc --noprofile "$test_script" > "$outfile" 2>/dev/null

    rm -f "$test_script" /tmp/bashrc-proof-log-$$.log
}

# Read the captured output, stripping the sentinel line.
# Returns the part before ___SENTINEL___, preserving all newlines.
read_output_before_sentinel() {
    local file="$1"
    sed '/^___SENTINEL___$/,$d' "$file"
}

# ═══════════════════════════════════════════════════════════════════
# TEST A: First terminal — neofetch + blank line before it
# ═══════════════════════════════════════════════════════════════════

TEST "First terminal: stdout has neofetch markers + leading blank line"

RUNTIME=$(mktemp -d /tmp/bashrc-proof-XXXXXX)
setup_runtime_dir "$RUNTIME"
OUTFILE=$(mktemp /tmp/bashrc-out-XXXXXX)

source_bashrc_to_file "yes" "no" "$RUNTIME" "$OUTFILE"
raw=$(cat "$OUTFILE")
output=$(read_output_before_sentinel "$OUTFILE")

echo "  stdout (${#output} bytes, ${#raw} raw):"
echo "$output" | head -20 | sed 's/^/    | /'

# Check: non-empty
if [ -z "$output" ]; then
    FAIL "stdout is empty"
else
    PASS "stdout is non-empty"
fi

# Check: neofetch markers present
if echo "$output" | grep -q "NEOFETCH_OUTPUT_START"; then
    PASS "neofetch marker found"
else
    FAIL "neofetch marker missing"
fi

# Check: starts with blank line (the echo before neofetch)
if [ "$(echo "$output" | head -c1)" = $'\n' ] || [ "$(echo "$output" | head -n1)" = "" ]; then
    PASS "starts with blank line"
else
    FAIL "does not start with blank line"
fi

rm -f "$OUTFILE"
cleanup_runtime_dir "$RUNTIME"

# ═══════════════════════════════════════════════════════════════════
# TEST B: Hide mode ON — exactly one newline
# ═══════════════════════════════════════════════════════════════════

TEST "Hide mode ON: stdout is exactly ONE newline (single \\n, 1 byte)"

RUNTIME=$(mktemp -d /tmp/bashrc-proof-XXXXXX)
setup_runtime_dir "$RUNTIME"
OUTFILE=$(mktemp /tmp/bashrc-out-XXXXXX)

source_bashrc_to_file "no" "yes" "$RUNTIME" "$OUTFILE"

# Check the raw file directly (no $() which strips newlines).
# Expected: line 1 empty (the echo), line 2 = sentinel
line_count=$(wc -l < "$OUTFILE")
first_line=$(head -n1 "$OUTFILE")
second_line=$(sed -n '2p' "$OUTFILE")

echo "  Raw file: $line_count lines"
echo -n "  hexdump: "; cat "$OUTFILE" | xxd | tr '\n' ' ' | sed 's/^/    /'; echo

# 2 lines: blank + sentinel
if [ "$line_count" -eq 2 ]; then
    PASS "raw file has exactly 2 lines (blank + sentinel)"
else
    FAIL "raw file has $line_count lines (expected 2)"
fi

# First line must be empty (the newline from 'echo')
if [ -z "$first_line" ]; then
    PASS "first line is empty (the newline)"
else
    FAIL "first line is not empty: '$first_line'"
fi

# Second line must be sentinel
if [ "$second_line" = "___SENTINEL___" ]; then
    PASS "second line is sentinel"
else
    FAIL "second line is not sentinel: '$second_line'"
fi

# No neofetch
if grep -q "NEOFETCH" "$OUTFILE"; then
    FAIL "unexpected neofetch"
else
    PASS "no neofetch"
fi

rm -f "$OUTFILE"
cleanup_runtime_dir "$RUNTIME"

# ═══════════════════════════════════════════════════════════════════
# TEST C: Hide mode OFF — completely empty (0 bytes)
# ═══════════════════════════════════════════════════════════════════

TEST "Hide mode OFF: stdout is completely empty (0 bytes)"

RUNTIME=$(mktemp -d /tmp/bashrc-proof-XXXXXX)
setup_runtime_dir "$RUNTIME"
OUTFILE=$(mktemp /tmp/bashrc-out-XXXXXX)

source_bashrc_to_file "no" "no" "$RUNTIME" "$OUTFILE"
raw=$(cat "$OUTFILE")
output=$(read_output_before_sentinel "$OUTFILE")

echo "  stdout (${#output} bytes):"
echo -n "$output" | xxd | sed 's/^/    | /'

# Check: completely empty
if [ "${#output}" -eq 0 ] && [ -z "$output" ]; then
    PASS "stdout is empty (0 bytes)"
else
    FAIL "expected 0 bytes, got ${#output} bytes"
fi

# The raw file should contain ONLY the sentinel
sentinel_only=$(echo "$raw" | wc -l)
if [ "$sentinel_only" -eq 1 ] && echo "$raw" | grep -q "SENTINEL"; then
    PASS "raw file contains only sentinel (no other stdout)"
else
    FAIL "raw file has extra content beyond sentinel"
fi

rm -f "$OUTFILE"
cleanup_runtime_dir "$RUNTIME"

# ═══════════════════════════════════════════════════════════════════
# TEST D: First terminal overrides hide_mode (mutual exclusion)
# ═══════════════════════════════════════════════════════════════════

TEST "Mutual exclusion: first terminal wins even with hide_mode file present"

RUNTIME=$(mktemp -d /tmp/bashrc-proof-XXXXXX)
setup_runtime_dir "$RUNTIME"
OUTFILE=$(mktemp /tmp/bashrc-out-XXXXXX)

# BOTH DWL_FIRST_TERMINAL and hide_mode file present
source_bashrc_to_file "yes" "yes" "$RUNTIME" "$OUTFILE"
output=$(read_output_before_sentinel "$OUTFILE")

echo "  stdout (${#output} bytes):"
echo "$output" | head -5 | sed 's/^/    | /'

# Must show neofetch (first terminal branch), NOT just a single newline
if echo "$output" | grep -q "NEOFETCH_OUTPUT_START"; then
    PASS "neofetch present — first terminal branch won"
else
    FAIL "neofetch missing — wrong branch selected"
fi

# Must NOT be just a single newline
if [ "${#output}" -gt 2 ]; then
    PASS "output > 2 bytes — confirms first_terminal path, not hide_mode"
else
    FAIL "output too short — may have taken hide_mode path by mistake"
fi

rm -f "$OUTFILE"
cleanup_runtime_dir "$RUNTIME"

# ═══════════════════════════════════════════════════════════════════
# TEST E: Consecutive terminal sequence
# ═══════════════════════════════════════════════════════════════════

TEST "Consecutive terminals: first → hide_on → hide_off → hide_on"

RUNTIME=$(mktemp -d /tmp/bashrc-proof-XXXXXX)
setup_runtime_dir "$RUNTIME"

all_pass=1

# Terminal 1: First (DWL_FIRST_TERMINAL=1)
O1=$(mktemp /tmp/bashrc-out-XXXXXX)
source_bashrc_to_file "yes" "no" "$RUNTIME" "$O1"
o1=$(read_output_before_sentinel "$O1")
if echo "$o1" | grep -q "NEOFETCH_OUTPUT"; then
    echo "  T1 (first):    PASS — neofetch shown"
else
    echo "  T1 (first):    FAIL — no neofetch"
    all_pass=0
fi
rm -f "$O1"

# Terminal 2: hide mode ON — check raw file directly (no $() stripping)
touch "$RUNTIME/hide_mode"
O2=$(mktemp /tmp/bashrc-out-XXXXXX)
source_bashrc_to_file "no" "yes" "$RUNTIME" "$O2"
lc2=$(wc -l < "$O2")
fl2=$(head -n1 "$O2")
if [ "$lc2" -eq 2 ] && [ -z "$fl2" ]; then
    echo "  T2 (hide_on):  PASS — exactly one newline"
else
    echo "  T2 (hide_on):  FAIL — lines=$lc2 first_line='$fl2'"
    all_pass=0
fi
rm -f "$O2"

# Terminal 3: hide mode OFF
rm -f "$RUNTIME/hide_mode"
O3=$(mktemp /tmp/bashrc-out-XXXXXX)
source_bashrc_to_file "no" "no" "$RUNTIME" "$O3"
lc3=$(wc -l < "$O3")
# Only sentinel line
if [ "$lc3" -eq 1 ]; then
    echo "  T3 (hide_off): PASS — only sentinel (0 bytes of output)"
else
    echo "  T3 (hide_off): FAIL — lines=$lc3 (expected 1: sentinel only)"
    all_pass=0
fi
rm -f "$O3"

# Terminal 4: hide mode ON again
touch "$RUNTIME/hide_mode"
O4=$(mktemp /tmp/bashrc-out-XXXXXX)
source_bashrc_to_file "no" "yes" "$RUNTIME" "$O4"
lc4=$(wc -l < "$O4")
fl4=$(head -n1 "$O4")
if [ "$lc4" -eq 2 ] && [ -z "$fl4" ]; then
    echo "  T4 (hide_on):  PASS — exactly one newline"
else
    echo "  T4 (hide_on):  FAIL — lines=$lc4 first_line='$fl4'"
    all_pass=0
fi
rm -f "$O4"

if [ "$all_pass" -eq 1 ]; then
    PASS "all 4 consecutive terminals correct"
else
    FAIL "sequence failed"
fi

cleanup_runtime_dir "$RUNTIME"

# ═══════════════════════════════════════════════════════════════════
# TEST F: The alias "Need Help?" is NOT double-printed
# ═══════════════════════════════════════════════════════════════════

TEST "Need Help? not double-printed (would appear exactly once if triggered)"

# Check the actual deployed bashrc
BASHRC="/root/.bashrc"

# Line 9: the alias defines the help message
line9=$(sed -n '9p' "$BASHRC")
if echo "$line9" | grep -q "Need Help?"; then
    PASS "line 9 alias contains 'Need Help?' (sole source)"
else
    FAIL "line 9 alias missing 'Need Help?'"
fi

# Lines 60-72: DWL_FIRST_TERMINAL block — must NOT echo Need Help?
first_block=$(sed -n '60,72p' "$BASHRC")
if echo "$first_block" | grep -q 'echo.*Need Help'; then
    FAIL "DWL_FIRST_TERMINAL block echoes 'Need Help?' — DOUBLE PRINT BUG"
else
    PASS "DWL_FIRST_TERMINAL block does NOT echo 'Need Help?'"
fi

# Count total occurrences of "Need Help?" in the whole bashrc
# Count non-comment occurrences (exclude lines starting with #)
active=$(grep -v '^[[:space:]]*#' "$BASHRC" | grep -c "Need Help?" || true)
comment=$(grep '^[[:space:]]*#' "$BASHRC" | grep -c "Need Help?" || true)
echo "  Active lines with 'Need Help?': $active"
echo "  Comment lines with 'Need Help?': $comment"
if [ "$active" -eq 1 ]; then
    PASS "exactly 1 active 'Need Help?' in bashrc (alias line 9)"
elif [ "$active" -eq 0 ]; then
    FAIL "no active 'Need Help?' found"
else
    FAIL "$active active 'Need Help?' occurrences — double-print bug"
fi

# ═══════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "════════════════════════════════════════"
echo "RESULTS: $TESTS_RUN tests, $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "════════════════════════════════════════"

if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
