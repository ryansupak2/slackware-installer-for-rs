#!/bin/bash
# elogind system-sleep hook — re-assert the power policy after resume.
# Installed by steps/power.sh as /lib64/elogind/system-sleep/power.sh
case "$1" in
    post)
        /usr/local/bin/power boot
        ;;
esac
exit 0
