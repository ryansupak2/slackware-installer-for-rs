#!/bin/bash
# elogind system-sleep hook: log only. Locking happens before suspend.
LOG_DIR="/var/log"
[ -w "$LOG_DIR" ] || LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/${USER:-root}-elogindsleep-$(date +%Y%m%d-%H%M%S).log"

case "$1" in
  pre)
    echo "$(date) elogind-sleep: pre-suspend" >> "$LOG"
    ;;
  post)
    echo "$(date) elogind-sleep: post-resume" >> "$LOG"
    ;;
esac
