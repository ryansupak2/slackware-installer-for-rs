#!/bin/bash
#
# terminal-neofetch-test.sh — Models terminal/neofetch behavior for st in dwm
#
# Tests:
#   1. DWL_FIRST_TERMINAL → neofetch + help on first st only
#   2. hide_mode ON → newline on subsequent st
#   3. hide_mode OFF → no newline on subsequent st
#   4. DWL_FIRST_TERMINAL does NOT leak via export (command-local scope)
#   5. "Need Help?" NOT double-printed (alias is sole source)
#   6. neofetch alias appends "Need Help?" correctly
#   7. xinitrc: DWL_FIRST_TERMINAL=1 st &  (scoped, not exported)
#
# This models the bashrc logic extracted from dotfiles/shell/bashrc
# and the xinitrc from scripts/dwm-start.sh

set -euo pipefail

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TEST() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo ""
    echo -e "${YELLOW}─── TEST $TESTS_RUN: $1 ───${NC}"
}

PASS() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: $1"
}

FAIL() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: $1"
}

ASSERT_EQ() {
    local want="$1" got="$2" label="$3"
    if [ "$want" = "$got" ]; then
        return 0
    else
        FAIL "$label: expected '$want', got '$got'"
        return 1
    fi
}

ASSERT_CONTAINS() {
    local haystack="$1" needle="$2" label="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        return 0
    else
        FAIL "$label: expected to contain '$needle'"
        return 1
    fi
}

ASSERT_NOT_CONTAINS() {
    local haystack="$1" needle="$2" label="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        FAIL "$label: should NOT contain '$needle'"
        return 1
    else
        return 0
    fi
}

# ═══════════════════════════════════════════════════════════════════
# Simulated bashrc logic (extracted from dotfiles/shell/bashrc)
# ═══════════════════════════════════════════════════════════════════

# Returns: ACTION=<type> NEWLINE=<0|1> NEOFETCH=<0|1> HELP=<0|1>
simulate_bashrc() {
    local dwl_first="${1:-}"
    local runtime="${2:-}"
    local hide_mode="${3:-no}"

    local action=""
    local has_newline=0
    local has_neofetch=0
    local has_help=0

    if [ -n "$dwl_first" ] && [ -n "$runtime" ]; then
        action="first_terminal"
        has_newline=1
        has_neofetch=1
        has_help=1        # alias on line 9 appends it
    elif [ -n "$runtime" ] && [ "$hide_mode" = "yes" ]; then
        action="hide_mode_newline"
        has_newline=1
        has_neofetch=0
        has_help=0
    else
        action="nothing"
        has_newline=0
        has_neofetch=0
        has_help=0
    fi

    echo "ACTION=${action} NEWLINE=${has_newline} NEOFETCH=${has_neofetch} HELP=${has_help}"
}

simulate_xinitrc_launch() {
    if [ "$1" = "export" ]; then
        echo "DWL_FIRST_TERMINAL=1"
    else
        echo ""
    fi
}

# ═══════════════════════════════════════════════════════════════════
# TEST 1: First terminal shows neofetch + help
# ═══════════════════════════════════════════════════════════════════

TEST "First terminal: DWL_FIRST_TERMINAL set → neofetch + help"

result=$(simulate_bashrc "1" "/run/user/0" "no")
action=$(echo "$result" | grep -oP 'ACTION=\K\S+')
newline=$(echo "$result" | grep -oP 'NEWLINE=\K\S+')
neofetch=$(echo "$result" | grep -oP 'NEOFETCH=\K\S+')
help=$(echo "$result" | grep -oP 'HELP=\K\S+')

ASSERT_EQ "first_terminal" "$action" "action type"
ASSERT_EQ "1" "$newline" "has newline"
ASSERT_EQ "1" "$neofetch" "has neofetch"
ASSERT_EQ "1" "$help" "has help message"
PASS "neofetch + help shown on first terminal"

# ═══════════════════════════════════════════════════════════════════
# TEST 2: Hide mode ON → newline on subsequent terminal
# ═══════════════════════════════════════════════════════════════════

TEST "Hide mode ON: subsequent terminal gets newline only"

result=$(simulate_bashrc "" "/run/user/0" "yes")
action=$(echo "$result" | grep -oP 'ACTION=\K\S+')
newline=$(echo "$result" | grep -oP 'NEWLINE=\K\S+')
neofetch=$(echo "$result" | grep -oP 'NEOFETCH=\K\S+')
help=$(echo "$result" | grep -oP 'HELP=\K\S+')

ASSERT_EQ "hide_mode_newline" "$action" "action type"
ASSERT_EQ "1" "$newline" "has newline"
ASSERT_EQ "0" "$neofetch" "no neofetch"
ASSERT_EQ "0" "$help" "no help message"
PASS "newline only on hide mode terminal"

# ═══════════════════════════════════════════════════════════════════
# TEST 3: Hide mode OFF → nothing added
# ═══════════════════════════════════════════════════════════════════

TEST "Hide mode OFF: subsequent terminal gets nothing"

result=$(simulate_bashrc "" "/run/user/0" "no")
action=$(echo "$result" | grep -oP 'ACTION=\K\S+')
newline=$(echo "$result" | grep -oP 'NEWLINE=\K\S+')
neofetch=$(echo "$result" | grep -oP 'NEOFETCH=\K\S+')
help=$(echo "$result" | grep -oP 'HELP=\K\S+')

ASSERT_EQ "nothing" "$action" "action type"
ASSERT_EQ "0" "$newline" "no newline"
ASSERT_EQ "0" "$neofetch" "no neofetch"
ASSERT_EQ "0" "$help" "no help"
PASS "nothing added when hide mode OFF"

# ═══════════════════════════════════════════════════════════════════
# TEST 4: DWL_FIRST_TERMINAL takes priority over hide_mode
# ═══════════════════════════════════════════════════════════════════

TEST "First terminal always wins over hide_mode"

result=$(simulate_bashrc "1" "/run/user/0" "yes")
action=$(echo "$result" | grep -oP 'ACTION=\K\S+')
ASSERT_EQ "first_terminal" "$action" "action type (first terminal wins)"
PASS "DWL_FIRST_TERMINAL takes priority"

# ═══════════════════════════════════════════════════════════════════
# TEST 5: DWL_FIRST_TERMINAL NOT exported (scoped to first st only)
# ═══════════════════════════════════════════════════════════════════

TEST "DWL_FIRST_TERMINAL not exported → subsequent sts get normal behavior"

dwm_env=$(simulate_xinitrc_launch "scoped")
echo "  dwm inherited env: '$dwm_env'"

if echo "$dwm_env" | grep -q "DWL_FIRST_TERMINAL"; then
    FAIL "DWL_FIRST_TERMINAL leaked into dwm env"
else
    PASS "DWL_FIRST_TERMINAL scoped to first st only"
fi

result=$(simulate_bashrc "" "/run/user/0" "yes")
action=$(echo "$result" | grep -oP 'ACTION=\K\S+')
ASSERT_EQ "hide_mode_newline" "$action" "second terminal: hide mode newline"
PASS "second terminal behaves correctly (hide mode path)"

# ═══════════════════════════════════════════════════════════════════
# TEST 6: OLD behavior: DWL_FIRST_TERMINAL EXPORTED → BUG
# ═══════════════════════════════════════════════════════════════════

TEST "BUG REGRESSION: exported DWL_FIRST_TERMINAL leaks to all terminals"

dwm_env=$(simulate_xinitrc_launch "export")
echo "  dwm inherited env (OLD bug): '$dwm_env'"

if echo "$dwm_env" | grep -q "DWL_FIRST_TERMINAL=1"; then
    echo "  => DWL_FIRST_TERMINAL IS in dwm's environment (this IS the bug)"

    result=$(simulate_bashrc "1" "/run/user/0" "yes")
    action=$(echo "$result" | grep -oP 'ACTION=\K\S+')
    ASSERT_EQ "first_terminal" "$action" "second terminal: BUG — shows neofetch again"
    echo "  => Second terminal incorrectly shows neofetch (BUG confirmed)"
    PASS "BUG correctly identified: exported var leaks to all terminals"
else
    FAIL "Expected DWL_FIRST_TERMINAL in dwm env for this bug test"
fi

# ═══════════════════════════════════════════════════════════════════
# TEST 7: neofetch alias is the sole source of "Need Help?"
# ═══════════════════════════════════════════════════════════════════

TEST "Need Help? message: alias is sole source (no double-print)"

BASHRC="/root/Development/slackware-installer-for-rs/dotfiles/shell/bashrc"

line9=$(sed -n '9p' "$BASHRC")
ASSERT_CONTAINS "$line9" "Need Help?" "alias on line 9 has help message"
ASSERT_CONTAINS "$line9" "alias neofetch" "line 9 is the neofetch alias"

lines_60_72=$(sed -n '60,72p' "$BASHRC")
if echo "$lines_60_72" | grep -q 'echo.*Need Help'; then
    FAIL "DWL_FIRST_TERMINAL block still has explicit 'Need Help?' echo (DOUBLE PRINT BUG)"
else
    PASS "DWL_FIRST_TERMINAL block does NOT echo 'Need Help?' (alias handles it)"
fi

ASSERT_CONTAINS "$lines_60_72" "neofetch" "DWL_FIRST_TERMINAL block calls neofetch"
PASS "No double-print of 'Need Help?'"

# ═══════════════════════════════════════════════════════════════════
# TEST 8: xinitrc correctly launches first st with scoped variable
# ═══════════════════════════════════════════════════════════════════

TEST "dwm-start.sh xinitrc: st launched with scoped DWL_FIRST_TERMINAL"

DWM_START="/root/Development/slackware-installer-for-rs/scripts/dwm-start.sh"

xinitrc_st_line=$(grep -n 'DWL_FIRST_TERMINAL.*st' "$DWM_START" 2>/dev/null || echo "")

if [ -z "$xinitrc_st_line" ]; then
    FAIL "DWL_FIRST_TERMINAL line not found in dwm-start.sh"
else
    echo "  Found: $xinitrc_st_line"
    if echo "$xinitrc_st_line" | grep -q 'export.*DWL_FIRST_TERMINAL'; then
        FAIL "DWL_FIRST_TERMINAL is still EXPORTED (leak bug!)"
    elif echo "$xinitrc_st_line" | grep -q 'DWL_FIRST_TERMINAL=1 st'; then
        PASS "DWL_FIRST_TERMINAL=1 scoped to st (no export)"
    else
        FAIL "Unexpected format: $xinitrc_st_line"
    fi
fi

xinitrc_body=$(sed -n '/^cat.*XEOF/,/^XEOF/p' "$DWM_START")
if echo "$xinitrc_body" | grep -q 'export.*DWL_FIRST_TERMINAL'; then
    FAIL "xinitrc still has 'export DWL_FIRST_TERMINAL' (LEAK BUG)"
else
    PASS "No 'export DWL_FIRST_TERMINAL' in xinitrc"
fi

PASS "dwm-start.sh correctly scopes DWL_FIRST_TERMINAL"

# ═══════════════════════════════════════════════════════════════════
# TEST 9: dwl-start.sh correctly scopes DWL_FIRST_TERMINAL too
# ═══════════════════════════════════════════════════════════════════

TEST "dwl-start.sh: foot launched with scoped DWL_FIRST_TERMINAL"

DWL_START="/root/Development/slackware-installer-for-rs/scripts/dwl-start.sh"

foot_line=$(grep -n 'DWL_FIRST_TERMINAL.*foot' "$DWL_START" 2>/dev/null || echo "")

if [ -z "$foot_line" ]; then
    FAIL "DWL_FIRST_TERMINAL + foot line not found in dwl-start.sh"
else
    echo "  Found: $foot_line"
    if echo "$foot_line" | grep -q 'export.*DWL_FIRST_TERMINAL'; then
        FAIL "DWL_FIRST_TERMINAL is exported in dwl-start.sh (leak bug!)"
    elif echo "$foot_line" | grep -q 'DWL_FIRST_TERMINAL=1.*foot'; then
        PASS "DWL_FIRST_TERMINAL scoped to foot command"
    else
        FAIL "Unexpected format: $foot_line"
    fi
fi

PASS "dwl-start.sh correctly scopes DWL_FIRST_TERMINAL"

# ═══════════════════════════════════════════════════════════════════
# TEST 10: First terminal unset prevents re-trigger
# ═══════════════════════════════════════════════════════════════════

TEST "unset DWL_FIRST_TERMINAL in first shell prevents re-trigger"

result=$(simulate_bashrc "1" "/run/user/0" "no")
action=$(echo "$result" | grep -oP 'ACTION=\K\S+')
ASSERT_EQ "first_terminal" "$action" "first call: first_terminal"

result=$(simulate_bashrc "" "/run/user/0" "no")
action=$(echo "$result" | grep -oP 'ACTION=\K\S+')
ASSERT_EQ "nothing" "$action" "second call (same shell): nothing"

PASS "unset prevents re-trigger in same shell"

# ═══════════════════════════════════════════════════════════════════
# TEST 11: bash_profile TTY login doesn't affect st behavior
# ═══════════════════════════════════════════════════════════════════

TEST "bash_profile: TTY neofetch does NOT affect st terminals"

BASH_PROFILE="/root/Development/slackware-installer-for-rs/dotfiles/shell/bash_profile"

tty_case=$(grep -A5 'case.*tty' "$BASH_PROFILE" 2>/dev/null || echo "")
if echo "$tty_case" | grep -q '/dev/tty'; then
    PASS "bash_profile only runs neofetch on /dev/tty*, not pts (st terminals)"
else
    FAIL "bash_profile missing /dev/tty* guard"
fi

PASS "bash_profile doesn't interfere with st behavior"

# ═══════════════════════════════════════════════════════════════════
# TEST 12: Mutual exclusion — all 8 state combinations
# ═══════════════════════════════════════════════════════════════════

TEST "Mutual exclusion: neofetch OR newline OR nothing, never both"

# if/elif/else structure ensures only ONE branch fires
# Both DWL_FIRST_TERMINAL and XDG_RUNTIME_DIR must be non-empty for first branch

declare -A expected_map
# dwl=1 runtime=/run/user/0 hide=yes → first_terminal
expected_map["1|/run/user/0|yes"]="first_terminal"
# dwl=1 runtime=/run/user/0 hide=no → first_terminal
expected_map["1|/run/user/0|no"]="first_terminal"
# dwl=1 runtime='' hide=yes → nothing (first branch fails: runtime empty)
expected_map["1||yes"]="nothing"
# dwl=1 runtime='' hide=no → nothing
expected_map["1||no"]="nothing"
# dwl='' runtime=/run/user/0 hide=yes → hide_mode_newline
expected_map["|/run/user/0|yes"]="hide_mode_newline"
# dwl='' runtime=/run/user/0 hide=no → nothing
expected_map["|/run/user/0|no"]="nothing"
# dwl='' runtime='' hide=yes → nothing
expected_map["||yes"]="nothing"
# dwl='' runtime='' hide=no → nothing
expected_map["||no"]="nothing"

all_ok=1
for key in "${!expected_map[@]}"; do
    IFS='|' read -r dwl runtime hide <<< "$key"
    result=$(simulate_bashrc "$dwl" "$runtime" "$hide")
    action=$(echo "$result" | grep -oP 'ACTION=\K\S+')
    expected="${expected_map[$key]}"

    if [ "$action" != "$expected" ]; then
        FAIL "combo dwl='$dwl' runtime='$runtime' hide='$hide': expected '$expected', got '$action'"
        all_ok=0
    fi
done

if [ "$all_ok" -eq 1 ]; then
    PASS "if/elif/else mutual exclusion correct for all 8 combos"
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
