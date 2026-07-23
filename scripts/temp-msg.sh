#!/bin/sh
# temp-msg.sh — shared helper: write a temporary status message
# Source this file, then call:  set_temp_msg "message" [duration=4]
set_temp_msg() {
    echo "$1" > "$XDG_RUNTIME_DIR/status_msg"
    echo $(($(date +%s) + ${2:-4})) > "$XDG_RUNTIME_DIR/status_end"
}
