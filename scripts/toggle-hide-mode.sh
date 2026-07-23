#!/bin/sh
# toggle-hide-mode.sh — toggle Hide Mode (Mod+H)
# Logs to stderr (captured by the dwm/dwl session log).

LOG_TAG="toggle-hide-mode"
log_me() { echo "$(date): [$LOG_TAG] $*" >&2; }

# Detect bar type: somebar-0 (Wayland) or dwmbar-0 (X11 dwm)
BAR_FIFO="${XDG_RUNTIME_DIR}/somebar-0"
[ ! -p "$BAR_FIFO" ] && BAR_FIFO="${XDG_RUNTIME_DIR}/dwmbar-0"
FIFO="$BAR_FIFO"
HIDE_MODE_FILE="$XDG_RUNTIME_DIR/hide_mode"
# Source shared temp-msg helper
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
