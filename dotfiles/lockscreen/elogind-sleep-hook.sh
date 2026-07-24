#!/bin/bash
# elogind system-sleep hook: lock screen before/after any suspend
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