#!/bin/sh
# toggle-hide-mode.sh — toggle Hide Mode (Mod+H)
# Logs to stderr (captured by the dwm session log).
FIFO="${XDG_RUNTIME_DIR}/dwmbar-0"
HIDE_MODE_FILE="$XDG_RUNTIME_DIR/hide_mode"
if [ -f /usr/local/bin/temp-msg.sh ]; then
    . /usr/local/bin/temp-msg.sh
fi

if [ -f "$HIDE_MODE_FILE" ]; then
    # Turn hide mode OFF
    log_me "hide mode OFF: removing $HIDE_MODE_FILE"
    rm -f "$HIDE_MODE_FILE"
    echo "hidemode off" > "$FIFO" 2>/dev/null
    echo "show all" > "$FIFO" 2>/dev/null
    set_temp_msg "(Hide Mode Off [Mod+H])"
else
    # Turn hide mode ON
    log_me "hide mode ON: creating $HIDE_MODE_FILE"
    touch "$HIDE_MODE_FILE"
    echo "hidemode on" > "$FIFO" 2>/dev/null
    echo "show all" > "$FIFO" 2>/dev/null
    set_temp_msg "(Hide Mode On [Mod+H])"
fi
