#!/bin/sh
# toggle-hide-mode.sh — toggle Hide Mode for somebar
# Mod+H keybinding in dwl triggers this

FIFO="${XDG_RUNTIME_DIR}/somebar-0"
HIDE_MODE_FILE="$XDG_RUNTIME_DIR/hide_mode"

# Source shared temp-msg helper
if [ -f /usr/local/bin/temp-msg.sh ]; then
    . /usr/local/bin/temp-msg.sh
fi

if [ -f "$HIDE_MODE_FILE" ]; then
    # Turn hide mode OFF
    rm -f "$HIDE_MODE_FILE"
    echo "hidemode off" > "$FIFO" 2>/dev/null
    echo "show all" > "$FIFO" 2>/dev/null
    set_temp_msg "(Hide Mode Off [Mod+H])"
else
    # Turn hide mode ON
    touch "$HIDE_MODE_FILE"
    echo "hidemode on" > "$FIFO" 2>/dev/null
    echo "show all" > "$FIFO" 2>/dev/null
    set_temp_msg "(Hide Mode On [Mod+H])"
fi
