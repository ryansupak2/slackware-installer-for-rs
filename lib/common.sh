#!/bin/bash
# lib/common.sh - Shared helpers for slackware-installer-for-rs post-install steps
# Sourced by individual step scripts and optionally by the main runner.

# ── Unified logging ────────────────────────────────────────────────────
# All scripts that source this file get a consistent log_msg() and init_log().
# Every log line gets a timestamp + level.
#
# NOTE: init_log() is DEPRECATED. Step scripts should NOT call it — the parent
# installer (post-install-global.sh / post-install-user.sh) already captures all
# output via `exec > >(tee -a "$LOG_FILE")`. Calling init_log() from a step
# would replace the tee redirect and hide output from the terminal.
#
# Step scripts should simply echo to stdout and exit 0/1; the parent handles
# logging and tallying.
#
# Usage:
init_log() {
    local component="${1:-unknown}"
    local user="${USER:-$(whoami 2>/dev/null || echo root)}"
    local logdir="/var/log"
    mkdir -p "$logdir" 2>/dev/null || true
    LOG_FILE="$logdir/${user}-${component}-$(date +%Y%m%d-%H%M%S).log"
    export LOG_FILE
    exec >>"$LOG_FILE" 2>&1
    echo "Log: $LOG_FILE"
}

log_msg() {
    local level="$1"; shift
    local msg="$*"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file="${LOG_FILE:-/var/log/installer.log}"
    echo "[$ts] [$level] $msg"
    if [ -n "$LOG_FILE" ]; then
        echo "[$ts] [$level] $msg" >> "$LOG_FILE"
    fi
}

# Helper: install official Slackware packages via slackpkg (no fallbacks)
install_pkg() {
    local pkgs="$1"
    log_msg INFO "Installing: $pkgs"
    for pkg in $pkgs; do
        if ls /var/log/packages/${pkg}-* >/dev/null 2>&1; then
            log_msg INFO "  $pkg already installed"
            continue
        fi
        log_msg INFO "  slackpkg install $pkg"
        slackpkg -batch=on -default_answer=y install "$pkg" 2>&1 | tee -a "$LOG_FILE"
        if [ "${PIPESTATUS[0]}" -ne 0 ]; then
            log_msg ERROR "Failed to install: $pkg"
            return 1
        fi
    done
    return 0
}

# Helper: install SBo packages via sbopkg (no fallbacks)
install_sbo() {
    local pkgs="$1"
    log_msg INFO "Installing via sbopkg: $pkgs"
    for pkg in $pkgs; do
        if ls /var/log/packages/${pkg}-* >/dev/null 2>&1; then
            log_msg INFO "  $pkg already installed"
            continue
        fi
        log_msg INFO "  sbopkg -B -i $pkg"
        sbopkg -B -e stop -i "$pkg" 2>&1 | tee -a "$LOG_FILE"
        if [ "${PIPESTATUS[0]}" -ne 0 ]; then
            log_msg ERROR "Failed to install via sbopkg: $pkg"
            return 1
        fi
    done
    return 0
}
