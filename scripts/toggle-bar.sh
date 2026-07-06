#!/bin/sh
# toggle-bar.sh — toggle somebar visibility (Mod+B)
# Always exits Hide Mode when used, since this is a manual override.

FIFO="${XDG_RUNTIME_DIR}/somebar-0"
HIDE_MODE_FILE="/tmp/hide_mode"

# Source shared temp-msg helper (guarded for bootstrap)
if [ -f /usr/local/bin/temp-msg.sh ]; then
    . /usr/local/bin/temp-msg.sh
else
    set_temp_msg() {
        echo "$1" > /tmp/status_msg
        echo $(($(date +%s) + ${2:-4})) > /tmp/status_end
    }
fi

if [ -f "$HIDE_MODE_FILE" ]; then
    # Hide Mode was ON — turn it off, show bar, display message
    rm -f "$HIDE_MODE_FILE"
    echo "hidemode off" > "$FIFO" 2>/dev/null
    set_temp_msg "(Hide Mode Off)"
else
    # Hide Mode already OFF — just toggle bar visibility
    echo "toggle all" > "$FIFO" 2>/dev/null
fi
