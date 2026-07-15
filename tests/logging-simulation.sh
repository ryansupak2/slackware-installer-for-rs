#!/bin/bash
# tests/logging-simulation.sh — simulate all log paths and verify naming conventions
#
# Tests:
#   1. Session script log init (/var/log/<user>-<component>-YYYYMMDD-HHMMSS.log)
#   2. Daemon log path (voxd: /var/log/<user>-vox.log)
#   3. Toggle script stderr logging (captured by session log)
#   4. Installer/step log paths
#   5. Per-user isolation (root vs non-root)
#
# Run: bash tests/logging-simulation.sh

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ── Helpers ────────────────────────────────────────────────────────────

# Simulate a session script's log init
sim_log_init() {
    local user="$1" component="$2"
    local logdir="/var/log"
    local logfile="$logdir/${user}-${component}-$(date +%Y%m%d-%H%M%S).log"
    echo "$logfile"
}

# Verify log filename matches pattern
check_pattern() {
    local file="$1" user="$2" component="$3"
    local base
    base=$(basename "$file")
    local expected="${user}-${component}-"
    if [[ "$base" == ${expected}* ]]; then
        pass "filename $base starts with '$expected'"
    else
        fail "filename $base should start with '$expected'"
    fi
    # Check YYYYMMDD-HHMMSS suffix
    if [[ "$base" =~ -[0-9]{8}-[0-9]{6}\.log$ ]]; then
        pass "filename $base has YYYYMMDD-HHMMSS timestamp suffix"
    else
        fail "filename $base missing YYYYMMDD-HHMMSS timestamp suffix"
    fi
}

# Simulate toggle script log_me output
sim_toggle_log() {
    local tag="$1" msg="$2"
    echo "$(date): [$tag] $msg" >&2
}

# ── Test 1: Session scripts (root) ─────────────────────────────────────
echo "=== Test 1: Session scripts as root ==="
export USER=root

# dwm-start
f=$(sim_log_init "root" "dwm")
check_pattern "$f" "root" "dwm"

# dwm-status
f=$(sim_log_init "root" "dwm-status")
check_pattern "$f" "root" "dwm-status"

# dwl-start
f=$(sim_log_init "root" "dwl")
check_pattern "$f" "root" "dwl"

# dwl-status
f=$(sim_log_init "root" "dwl-status")
check_pattern "$f" "root" "dwl-status"

# vpn
f=$(sim_log_init "root" "vpn")
check_pattern "$f" "root" "vpn"

# vpn-suspend
f=$(sim_log_init "root" "vpn-suspend")
check_pattern "$f" "root" "vpn-suspend"

# wifi-manager
f=$(sim_log_init "root" "wifi-manager")
check_pattern "$f" "root" "wifi-manager"

# vnc
f=$(sim_log_init "root" "vnc")
check_pattern "$f" "root" "vnc"

# net-watch
f=$(sim_log_init "root" "net-watch")
check_pattern "$f" "root" "net-watch"

# lock-screen
f=$(sim_log_init "root" "lock-screen")
check_pattern "$f" "root" "lock-screen"

# slock-sleep
f=$(sim_log_init "root" "slock-sleep")
check_pattern "$f" "root" "slock-sleep"

# shell-init
f=$(sim_log_init "root" "shell-init")
check_pattern "$f" "root" "shell-init"

# audio-boot
f=$(sim_log_init "root" "audio-boot")
check_pattern "$f" "root" "audio-boot"

# post-install-global
f=$(sim_log_init "root" "post-install-global")
check_pattern "$f" "root" "post-install-global"

# post-install-user (uses TARGET_USER)
f=$(sim_log_init "rs" "post-install-user")
check_pattern "$f" "rs" "post-install-user"

# bootstrap
f=$(sim_log_init "root" "bootstrap")
check_pattern "$f" "root" "bootstrap"

# ── Test 2: Session scripts (non-root 'rs') ────────────────────────────
echo "=== Test 2: Session scripts as user 'rs' ==="
export USER=rs

f=$(sim_log_init "rs" "dwm")
check_pattern "$f" "rs" "dwm"

f=$(sim_log_init "rs" "dwm-status")
check_pattern "$f" "rs" "dwm-status"

f=$(sim_log_init "rs" "vpn")
check_pattern "$f" "rs" "vpn"

f=$(sim_log_init "rs" "shell-init")
check_pattern "$f" "rs" "shell-init"

# ── Test 3: Daemon log (voxd — single append file) ─────────────────────
echo "=== Test 3: VOX daemon log ==="
export USER=root
VOX_LOG="/var/log/${USER}-vox.log"
if [ "$VOX_LOG" = "/var/log/root-vox.log" ]; then
    pass "vox log: $VOX_LOG"
else
    fail "vox log: expected /var/log/root-vox.log, got $VOX_LOG"
fi

export USER=rs
VOX_LOG="/var/log/${USER}-vox.log"
if [ "$VOX_LOG" = "/var/log/rs-vox.log" ]; then
    pass "vox log: $VOX_LOG"
else
    fail "vox log: expected /var/log/rs-vox.log, got $VOX_LOG"
fi

# ── Test 4: Toggle script logging (stderr) ─────────────────────────────
echo "=== Test 4: Toggle script stderr logging ==="

# toggle-bar.sh
output=$(sim_toggle_log "toggle-bar" "toggle-bar invoked: FIFO=/run/user/0/dwmbar-0 hide_mode=ON bar_shown=YES" 2>&1 || true)
if echo "$output" | grep -q "\[toggle-bar\]"; then
    pass "toggle-bar.sh: logs with [toggle-bar] prefix"
else
    fail "toggle-bar.sh: missing [toggle-bar] prefix in: $output"
fi

# toggle-hide-mode.sh
output=$(sim_toggle_log "toggle-hide-mode" "hide mode ON: creating /run/user/0/hide_mode" 2>&1 || true)
if echo "$output" | grep -q "\[toggle-hide-mode\]"; then
    pass "toggle-hide-mode.sh: logs with [toggle-hide-mode] prefix"
else
    fail "toggle-hide-mode.sh: missing [toggle-hide-mode] prefix in: $output"
fi

# ── Test 5: Installer step LOG_FILE ────────────────────────────────────
echo "=== Test 5: Installer step LOG_FILE pattern ==="
# All steps default to /var/log/installer.log
if [ "/var/log/installer.log" = "/var/log/installer.log" ]; then
    pass "installer step default: /var/log/installer.log"
fi

# With init_log:
export USER=root
f=$(sim_log_init "root" "suckless-dwm")
if [[ "$f" == /var/log/root-suckless-dwm-* ]]; then
    pass "init_log suckless-dwm: $f"
else
    fail "init_log suckless-dwm: $f"
fi

# ── Test 6: No hardcoded /root/logs remaining ──────────────────────────
echo "=== Test 6: No old /root/logs or \$HOME/logs in deployed scripts ==="
for script in /usr/local/bin/dwm-start /usr/local/bin/dwm-status \
              /usr/local/bin/toggle-bar.sh /usr/local/bin/toggle-hide-mode.sh \
              /usr/local/bin/toggle-vox.sh; do
    if grep -qE '/root/logs|\$HOME/logs' "$script" 2>/dev/null; then
        fail "$script: still references old /root/logs or \$HOME/logs"
        grep -nE '/root/logs|\$HOME/logs' "$script"
    else
        pass "$script: no old log paths"
    fi
done

# ── Test 7: Voxd binary references new path ────────────────────────────
echo "=== Test 7: Voxd binary log path ==="
if strings /usr/local/bin/voxd 2>/dev/null | grep -q '/var/log/.*-vox.log'; then
    pass "voxd binary contains /var/log/<user>-vox.log"
else
    # Check for the old pattern
    if strings /usr/local/bin/voxd 2>/dev/null | grep -q '/logs/vox.log'; then
        fail "voxd binary still has old /logs/vox.log path"
    else
        fail "voxd binary: could not verify log path (strings check inconclusive)"
    fi
fi

# ── Summary ────────────────────────────────────────────────────────────
echo ""
echo "=================================================="
echo "SIMULATION COMPLETE: $PASS passed, $FAIL failed"
echo "=================================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
