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
    # Hide Mode was ON — turn it off, show bar with bar-visible message
    rm -f "$HIDE_MODE_FILE"
    echo "hidemode off" > "$FIFO" 2>/dev/null
    set_temp_msg "(Bar Visible [Mod+B])"
else
    # Hide Mode already OFF — toggle bar visibility
    BAR_STATE="/tmp/bar_shown"
    if [ -f "$BAR_STATE" ]; then
        # Bar is visible — hide it, no message
        rm -f "$BAR_STATE"
        echo "hide all" > "$FIFO" 2>/dev/null
    else
        # Bar is hidden — show it with message
        touch "$BAR_STATE"
        echo "show all" > "$FIFO" 2>/dev/null
        set_temp_msg "(Bar Visible [Mod+B])"
    fi
fi
