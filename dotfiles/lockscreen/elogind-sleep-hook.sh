#!/bin/bash
# elogind system-sleep hook: lock screen before suspend
case "$1" in
  pre)
    /usr/local/bin/lock-screen.sh &
    ;;
esac