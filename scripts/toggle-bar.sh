#!/bin/sh
# toggle-bar.sh — toggle somebar visibility (Mod+B)
# Always exits Hide Mode, then toggles bar visibility.

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

# Always turn off Hide Mode
if [ -f "$HIDE_MODE_FILE" ]; then
    rm -f "$HIDE_MODE_FILE"
    echo "hidemode off" > "$FIFO" 2>/dev/null
fi

# Toggle bar visibility
BAR_STATE="/tmp/bar_shown"
if [ -f "$BAR_STATE" ]; then
    # Bar visible — hide it (no message)
    echo "hide all" > "$FIFO" 2>/dev/null
else
    # Bar invisible — show it
    echo "show all" > "$FIFO" 2>/dev/null
    set_temp_msg "(Hide Mode Off + Bar Visible [Mod+B])"
fi
