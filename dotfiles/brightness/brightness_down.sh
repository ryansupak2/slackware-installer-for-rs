#!/bin/sh
# brightness_down.sh — panel backlight down one step (bound to XF86MonBrightnessDown)
#
# Goes through `power set brightness`, which also marks brightness as a MANUAL
# choice: the power policy (auto AC/battery mode) must never fight the user's
# own setting afterwards. `power profile <name>` hands control back to the policy.
# Falls back to writing sysfs directly if the power tool is unavailable.

if [ -f /usr/local/bin/temp-msg.sh ]; then . /usr/local/bin/temp-msg.sh
else set_temp_msg() { echo "$1" > "$XDG_RUNTIME_DIR/status_msg"; echo $(($(date +%s) + ${2:-4})) > "$XDG_RUNTIME_DIR/status_end"; }; fi

DEV=$(ls /sys/class/backlight/ 2>/dev/null | head -1)
[ -n "$DEV" ] || exit 0
MAX=$(cat "/sys/class/backlight/$DEV/max_brightness" 2>/dev/null) || exit 0
CUR=$(cat "/sys/class/backlight/$DEV/brightness" 2>/dev/null) || exit 0
[ "$MAX" -gt 0 ] 2>/dev/null || exit 0

NEW=$((CUR - MAX / 20))
[ "$NEW" -lt 1 ] && NEW=1
PCT=$((NEW * 100 / MAX))
[ "$PCT" -lt 1 ] && PCT=1

if [ -x /usr/local/bin/power ] && { [ "$(id -u)" -eq 0 ] || sudo -n -l /usr/local/bin/power >/dev/null 2>&1; }; then
    /usr/local/bin/power set brightness "$PCT" >/dev/null 2>&1
else
    echo "$NEW" > "/sys/class/backlight/$DEV/brightness" 2>/dev/null || exit 0
fi

set_temp_msg "Brightness: $PCT%"
