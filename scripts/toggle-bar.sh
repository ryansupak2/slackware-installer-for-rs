#!/bin/sh
# toggle-bar.sh — toggle bar visibility (Mod+B)
# Always exits Hide Mode, then toggles bar visibility.
# Logs to stderr (captured by the dwm/dwl session log).

LOG_TAG="toggle-bar"
log_me() { echo "$(date): [$LOG_TAG] $*" >&2; }

# Detect bar type: somebar-0 (Wayland) or dwmbar-0 (X11 dwm)
BAR_FIFO="${XDG_RUNTIME_DIR}/somebar-0"
[ ! -p "$BAR_FIFO" ] && BAR_FIFO="${XDG_RUNTIME_DIR}/dwmbar-0"
FIFO="$BAR_FIFO"
HIDE_MODE_FILE="$XDG_RUNTIME_DIR/hide_mode"
# State file: somebar sets bar_shown, dwm we track ourselves
if [ "$BAR_FIFO" = "${XDG_RUNTIME_DIR}/dwmbar-0" ]; then
	BAR_STATE="$XDG_RUNTIME_DIR/dwm_bar_shown"
else
	BAR_STATE="$XDG_RUNTIME_DIR/bar_shown"
fi

# Source shared temp-msg helper
if [ -f /usr/local/bin/temp-msg.sh ]; then
    . /usr/local/bin/temp-msg.sh
fi

log_me "toggle-bar invoked: FIFO=$FIFO hide_mode=$(test -f $HIDE_MODE_FILE && echo ON || echo OFF) bar_shown=$(test -f $BAR_STATE && echo YES || echo NO)"

# Always turn off Hide Mode
if [ -f "$HIDE_MODE_FILE" ]; then
    log_me "exiting hide mode: removing $HIDE_MODE_FILE"
    rm -f "$HIDE_MODE_FILE"
    echo "hidemode off" > "$FIFO" 2>/dev/null
fi

# Toggle bar visibility
if [ -f "$BAR_STATE" ]; then
	# Bar visible — hide it (no message)
	log_me "hiding bar: sending 'hide all' to FIFO"
	echo "hide all" > "$FIFO" 2>/dev/null
	rm -f "$BAR_STATE"
else
	# Bar invisible — show it
	log_me "showing bar: sending 'show all' to FIFO"
	echo "show all" > "$FIFO" 2>/dev/null
	touch "$BAR_STATE"
	set_temp_msg "(Hide Mode Off + Bar Visible [Mod+B])"
fi
