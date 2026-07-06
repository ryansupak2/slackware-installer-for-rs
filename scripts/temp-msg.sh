#!/bin/sh
# temp-msg.sh — shared helper: write a temporary status message
# Source this file, then call:  set_temp_msg "message" [duration=4]
set_temp_msg() {
    echo "$1" > /tmp/status_msg
    echo $(($(date +%s) + ${2:-4})) > /tmp/status_end
}
