#!/bin/bash
# elogind system-sleep hook: extra safety net.
# Backlight + primary lock/unlock is handled by lid-timer.sh.
# This just ensures lock-screen.sh runs at the right times.

case "$1" in
  pre)
    /usr/local/bin/lock-screen.sh &
    sleep 0.3
    ;;
  post)
    /usr/local/bin/lock-screen.sh &
    sleep 0.5
    ;;
esac
