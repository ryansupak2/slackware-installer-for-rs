#!/bin/bash
# tests/installer-simulation.sh — simulate full installer flow and audit consistency
#
# Run: REPO_DIR=/root/Development/slackware-installer-for-rs bash tests/installer-simulation.sh

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_DIR="${REPO_DIR:-/root/Development/slackware-installer-for-rs}"
STEPS_DIR="$REPO_DIR/steps"

# ── Test 1: All step scripts pass bash -n ───────────────────────────────
echo "=== Test 1: bash -n syntax check on all step scripts ==="
for s in "$STEPS_DIR"/*.sh; do
    name=$(basename "$s")
    if bash -n "$s" 2>&1; then
        pass "bash -n: $name"
    else
        fail "bash -n: $name"
    fi
done

# ── Test 2: REPO_DIR defaults consistent ────────────────────────────────
echo "=== Test 2: REPO_DIR default consistency ==="
for s in "$STEPS_DIR"/*.sh; do
    name=$(basename "$s")
    default=$(grep 'REPO_DIR=' "$s" 2>/dev/null | head -1)
    if [ -z "$default" ]; then
        fail "REPO_DIR: $name — no REPO_DIR default line"
    elif echo "$default" | grep -q '/root/slackware-installer-for-rs'; then
        pass "REPO_DIR: $name — canonical default"
    else
        fail "REPO_DIR: $name — non-canonical: $default"
    fi
done

# ── Test 3: common.sh sourcing ──────────────────────────────────────────
echo "=== Test 3: common.sh sourcing ==="
for s in "$STEPS_DIR"/*.sh; do
    name=$(basename "$s")
    if grep -q 'lib/common.sh' "$s" 2>/dev/null; then
        pass "common.sh: $name"
    else
        fail "common.sh: $name — does not source lib/common.sh"
    fi
done

# ── Test 4: Step header banner ───────────────────────────────────────
echo "=== Test 4: Step header banner ==="
for s in "$STEPS_DIR"/*.sh; do
    name=$(basename "$s")
    if grep -qE 'echo "\*{20,}"' "$s" 2>/dev/null; then
        pass "banner: $name"
    else
        fail "banner: $name — missing ***** header banner"
    fi
done

# ── Test 5: Step error handling ────────────────────────────────────────
echo "=== Test 5: Step error handling ==="
TRIVIAL="pi-update.sh pi-double-input-fix.sh"
for s in "$STEPS_DIR"/*.sh; do
    name=$(basename "$s")
    if echo "$TRIVIAL" | grep -qw "$name"; then
        pass "error-handling: $name (trivial — exempt)"
        continue
    fi
    has_ok=$(grep -cE '(^|[^a-z])ok=true' "$s" 2>/dev/null || true)
    has_direct_if=$(grep -cE 'if install_(pkg|sbo)' "$s" 2>/dev/null || true)
    has_success=$(grep -cE 'echo "SUCCESS' "$s" 2>/dev/null || true)
    has_error=$(grep -c 'exit 1' "$s" 2>/dev/null || true)
    if [ "$has_ok" -ge 1 ] || [ "$has_direct_if" -ge 1 ]; then
        pass "error-handling: $name"
    elif [ "$has_success" -ge 1 ] && [ "$has_error" -ge 1 ]; then
        pass "error-handling: $name (SUCCESS/ERROR exit pattern)"
    else
        fail "error-handling: $name — no ok=true or install_pkg if/else"
    fi
done

# ── Test 6: Category step names all exist ───────────────────────────────
echo "=== Test 6: Category → step file coverage ==="
GLOBAL="$REPO_DIR/post-install-global.sh"
# Extract quoted step names from category array lines, filter to dashed-names only
CAT_STEPS=$(grep -E '^[a-z_]+=\("' "$GLOBAL" | tr '"' '\n' | grep -E '^[a-z][a-z-]+$' | sort -u)
for step in $CAT_STEPS; do
    if [ -f "$STEPS_DIR/$step.sh" ]; then
        pass "coverage: $step → $step.sh"
    elif [ "$step" = "root-shortcuts" ]; then
        pass "coverage: root-shortcuts → user-surf-shortcuts.sh (by design)"
    else
        fail "coverage: $step → $step.sh MISSING"
    fi
done

# ── Test 7: Wayland steps archived and unreachable ──────────────────────
echo "=== Test 7: Wayland steps archived ==="
WAYLAND_STEPS="wayland-base suckless-dwl suckless-foot clipboard-wayland remote-desktop"
for step in $WAYLAND_STEPS; do
    if [ -f "$STEPS_DIR/archive/$step.sh" ]; then
        pass "archived: $step.sh in archive/"
    else
        fail "archived: $step.sh NOT in archive/"
    fi
    if [ -f "$STEPS_DIR/$step.sh" ]; then
        fail "archived: $step.sh still in active steps/"
    else
        pass "archived: $step.sh removed from active"
    fi
    if grep -E '^[a-z_]+=\("' "$GLOBAL" | grep -q "\"$step\""; then
        fail "archived: $step still in category array"
    else
        pass "archived: $step not in category arrays"
    fi
    if awk '/case \$section in/,/^esac/' "$GLOBAL" | grep -q "\"$step\""; then
        fail "archived: $step still in case statement"
    else
        pass "archived: $step not in case statement"
    fi
done

# ── Test 8: X11 steps reachable ─────────────────────────────────────────
echo "=== Test 8: X11 steps reachable ==="
for step in xlibre suckless-dwm; do
    if [ -f "$STEPS_DIR/$step.sh" ]; then
        pass "X11: $step.sh exists"
    else
        fail "X11: $step.sh MISSING"
    fi
    if grep -E '^[a-z_]+=\("' "$GLOBAL" | grep -q "\"$step\""; then
        pass "X11: $step in category array"
    else
        fail "X11: $step NOT in category array"
    fi
    if awk '/case \$section in/,/^esac/' "$GLOBAL" | grep -q "\"$step\""; then
        pass "X11: $step in case statement"
    else
        fail "X11: $step NOT in case statement"
    fi
done

# ── Test 9: Debug variant consistency ───────────────────────────────────
echo "=== Test 9: Debug variant consistency ==="
DEBUG="$REPO_DIR/post-install-global-debug.sh"
if head -5 "$DEBUG" | grep -q 'DEBUG/NO-X11 VARIANT'; then
    pass "debug: relationship comment present"
else
    fail "debug: missing relationship comment"
fi
for step in root-dotfiles sof-firmware whisper-cpp-vox; do
    if grep -E '^[a-z_]+=\("' "$DEBUG" | grep -q "\"$step\""; then
        fail "debug: $step should be absent"
    else
        pass "debug: $step correctly absent"
    fi
done
for step in xlibre suckless-dwm; do
    if grep -E '^[a-z_]+=\("' "$DEBUG" | grep -q "\"$step\""; then
        pass "debug: $step present (matches main)"
    else
        fail "debug: $step missing from debug variant"
    fi
done

# ── Test 10: Bootstrap integrity ────────────────────────────────────────
echo "=== Test 10: Bootstrap integrity ==="
BOOTSTRAP="$REPO_DIR/bootstrap.sh"
[ -f "$BOOTSTRAP" ] && pass "bootstrap: exists" || fail "bootstrap: MISSING"
head -1 "$BOOTSTRAP" | grep -q '#!/bin/bash' && pass "bootstrap: shebang" || fail "bootstrap: shebang"
grep -q 'LOG_DIR="/var/log"' "$BOOTSTRAP" 2>/dev/null && pass "bootstrap: LOG_DIR" || fail "bootstrap: LOG_DIR"
grep -q 'success_count' "$BOOTSTRAP" 2>/dev/null && pass "bootstrap: success_count" || fail "bootstrap: success_count"

# ── Test 11: post-install-user.sh step coverage ─────────────────────────
echo "=== Test 11: User step coverage ==="
USER_SCRIPT="$REPO_DIR/post-install-user.sh"
# Extract step paths from step_list (matches "./steps/user-foo.sh" but not globs)
USER_STEPS=$(grep -o '\./steps/user-[a-z][a-z-]*\.sh' "$USER_SCRIPT" 2>/dev/null | sed 's|.*/||' | sort -u)
for step in $USER_STEPS; do
    if [ -f "$STEPS_DIR/$step" ]; then
        pass "user-step: $step exists"
    else
        fail "user-step: $step MISSING"
    fi
done
# All user-*.sh should be listed except user-ensure (PHASE 1 special)
for s in "$STEPS_DIR"/user-*.sh; do
    name=$(basename "$s")
    if [ "$name" = "user-ensure.sh" ]; then
        pass "user-coverage: $name (PHASE 1 special — exempt)"
        continue
    fi
    if echo "$USER_STEPS" | grep -qw "$name"; then
        pass "user-coverage: $name listed"
    else
        fail "user-coverage: $name NOT listed in post-install-user.sh"
    fi
done

# ── Summary ────────────────────────────────────────────────────────────
echo ""
echo "=================================================="
echo "SIMULATION COMPLETE: $PASS passed, $FAIL failed"
echo "=================================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
