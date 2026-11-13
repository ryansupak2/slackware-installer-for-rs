#!/bin/sh
# dwm-background — show or set THIS user's dwm desktop background colour
#
# Resolution order (same as scripts/dwm-start.sh):
#   ~/.dwm-background        per-user override (this tool writes it)
#   /etc/dwm/backgrounds.conf  user=<colour> line, then default=
#   #808080                    compiled-in fallback
#
# Usage:
#   dwm-background                 print the colour currently in effect
#   dwm-background '#5a5a5a'       set it for this user and apply now
#   dwm-background --reset         drop the override (back to system default)
#
# The value must be an X colour: #RGB / #RRGGBB (a plain name such as "grey40"
# also works). Takes effect immediately when DISPLAY is available, and at every
# future X start.

CONF=/etc/dwm/backgrounds.conf
OVERRIDE="${HOME:-/root}/.dwm-background"
FALLBACK='#808080'

valid_colour() {
    case "$1" in
        '#'[0-9a-fA-F]*) ;;
        [a-zA-Z]*) ;;
        *) return 1 ;;
    esac
    # X also accepts a few non-hex names, so only reject shell-poison values.
    case "$1" in
        *[!a-zA-Z0-9#,./+-]*) return 1 ;;
    esac
    return 0
}

conf_lookup() {
    [ -r "$CONF" ] || return 0
    awk -F= -v u="$1" '
        { k=$1; v=$2; gsub(/[ \t]/, "", k); gsub(/[ \t]/, "", v) }
        k == u         { print v; found=1; exit }
        k == "default" { d=v }
        END            { if (!found && d != "") print d }
    ' "$CONF"
}

current() {
    if [ -r "$OVERRIDE" ]; then
        head -1 "$OVERRIDE" | tr -d ' \t\r\n'
        return 0
    fi
    c=$(conf_lookup "$(id -un)")
    [ -n "$c" ] || c=$FALLBACK
    printf '%s\n' "$c"
}

apply() {
    [ -n "${DISPLAY:-}" ] || return 0
    command -v xsetroot >/dev/null 2>&1 || return 0
    xsetroot -solid "$1" 2>/dev/null && echo "applied to DISPLAY=$DISPLAY"
}

case "${1:-}" in
    ''|--show)
        current
        ;;
    --help|-h)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    --reset)
        rm -f "$OVERRIDE"
        c=$(conf_lookup "$(id -un)")
        [ -n "$c" ] || c=$FALLBACK
        printf 'reset to %s\n' "$c"
        apply "$c"
        ;;
    *)
        if ! valid_colour "$1"; then
            echo "dwm-background: invalid colour '$1' (use #RRGGBB or a name)" >&2
            exit 2
        fi
        printf '%s\n' "$1" > "$OVERRIDE" || exit 1
        printf 'set %s\n' "$1"
        apply "$1"
        ;;
esac
