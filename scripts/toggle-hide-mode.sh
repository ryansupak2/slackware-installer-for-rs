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
    set_temp_msg "(Hide Mode Off + Bar Visible [Mod+H])"
    echo "hidemode off" > "$FIFO" 2>/dev/null
else
    # Hide Mode OFF — decide based on bar visibility
    BAR_STATE="/tmp/bar_shown"
    if [ -f "$BAR_STATE" ]; then
        # Bar visible — turn Hide Mode ON (bar will auto-hide)
        touch "$HIDE_MODE_FILE"
        echo "hidemode on" > "$FIFO" 2>/dev/null
        echo "show all" > "$FIFO" 2>/dev/null
        set_temp_msg "(Hide Mode On + Bar Visible [Mod+H])"
    else
        # Bar invisible (Mod+B'd) — just show it, don't enable Hide Mode
        echo "show all" > "$FIFO" 2>/dev/null
        if [ -f "$HIDE_MODE_FILE" ]; then
            set_temp_msg "(Hide Mode On + Bar Visible [Mod+H])"
        else
            set_temp_msg "(Hide Mode Off + Bar Visible [Mod+H])"
        fi
    fi
fi
