#!/bin/bash
# lib/common.sh - Shared helpers for slackware-installer-for-rs post-install steps
# Sourced by individual step scripts and optionally by the main runner.

# ── Unified logging ────────────────────────────────────────────────────
# All scripts that source this file get a consistent log_msg() and the
# caller's LOG_FILE is respected.  Every log line gets a timestamp + level.

log_msg() {
    local level="$1"; shift
    local msg="$*"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file="${LOG_FILE:-$HOME/logs/installer.log}"
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
