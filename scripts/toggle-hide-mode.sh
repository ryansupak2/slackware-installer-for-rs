#!/bin/sh
# toggle-hide-mode.sh — toggle Hide Mode for somebar
# Mod+H keybinding in dwl triggers this

FIFO="${XDG_RUNTIME_DIR}/somebar-0"
HIDE_MODE_FILE="/tmp/hide_mode"

# Source shared temp-msg helper (guarded for when it may not yet be installed)
if [ -f /usr/local/bin/temp-msg.sh ]; then
    . /usr/local/bin/temp-msg.sh
else
    # Fallback: inline the function
    set_temp_msg() {
        echo "$1" > /tmp/status_msg
        echo $(($(date +%s) + ${2:-4})) > /tmp/status_end
    }
fi

if [ -f "$HIDE_MODE_FILE" ]; then
    # Turn hide mode OFF — show bar, message stays for 3s
    rm -f "$HIDE_MODE_FILE"
    set_temp_msg "(Hide Mode Off)"
    echo "hidemode off" > "$FIFO" 2>/dev/null
else
    # Turn hide mode ON — show bar with message, then hide after 3s
    touch "$HIDE_MODE_FILE"
    set_temp_msg "(Hide Mode On [Mod+H])"
    echo "show all" > "$FIFO" 2>/dev/null
    (sleep 3; [ -f "$HIDE_MODE_FILE" ] && echo "hidemode on" > "$FIFO" 2>/dev/null) &
fi
