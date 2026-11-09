#!/bin/sh
# chromium-ui-font — size the locally built Chromium's URL bar and tab labels
# INDEPENDENTLY, without rebuilding anything.
#
# Why this exists: in stock Chromium both sizes come from one UI font (the GTK
# gtk-font-name) times a compiled-in per-element offset — the URL bar asks for
# a 14pt target, tab labels for 12pt — so they can only be moved together.
# patches/chromium/0001-per-element-ui-font-deltas.patch adds a dedicated
# typography context for the tab strip plus a runtime point-delta for both,
# read from /etc/chromium/ui-font.conf at startup.
#
# Usage:
#   chromium-ui-font                  show current/effective sizes
#   chromium-ui-font show             same
#   chromium-ui-font omnibox 16       set URL bar text to 16pt (effective)
#   chromium-ui-font tab 13           set tab strip text to 13pt (effective)
#   chromium-ui-font omnibox +2       add 2pt to the current URL bar delta
#   chromium-ui-font tab -1
#   chromium-ui-font reset            stock deltas (0/0)
#
# Effective size = GTK UI font size + element offset + delta, where the offsets
# are Chromium's own: URL bar +2, tab strip 0 (relative to the 12pt base).
# The browser must be restarted: deltas are read once per process.

CONF="${CHROMIUM_UI_FONT_CONF:-/etc/chromium/ui-font.conf}"
GTK_INI="${HOME:-/root}/.config/gtk-3.0/settings.ini"

# Chromium's built-in targets (Chromium 157: kDefaultSize 12, omnibox 14).
BASE_PT=12
OMNIBOX_OFFSET=2
TAB_OFFSET=0
MIN_DELTA=-6
MAX_DELTA=10

die() { echo "ERROR: $*" >&2; exit 1; }

gtk_size() {
    size=""
    [ -f "$GTK_INI" ] && size=$(sed -n 's/^gtk-font-name=.*[^0-9]\([0-9][0-9]*\)$/\1/p' "$GTK_INI" | head -1)
    [ -n "$size" ] || size=$BASE_PT
    echo "$size"
}

conf_get() {   # $1 = key -> prints int delta
    [ -f "$CONF" ] || { echo 0; return; }
    v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(-\{0,1\}[0-9]\{1,\}\)[[:space:]]*$/\1/p" "$CONF" | tail -1)
    [ -n "$v" ] || v=0
    echo "$v"
}

conf_write() {   # $1 = omnibox delta, $2 = tab delta
    dir=$(dirname "$CONF")
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || die "cannot create $dir (run as root)"
    header=""
    [ -f "$CONF" ] && header=$(grep '^#' "$CONF")
    tmp=$(mktemp "${CONF}.XXXXXX") || die "cannot write next to $CONF"
    {
        if [ -n "$header" ]; then
            printf '%s\n' "$header"
        else
            echo "# Written by chromium-ui-font — see dotfiles/chromium/ui-font.conf"
            echo "# Effective size = GTK UI font + Chromium offset (URL bar +2, tabs 0) + delta"
        fi
        printf '\n%s\n%s\n' "omnibox_delta=$1" "tab_delta=$2"
    } > "$tmp" || { rm -f "$tmp"; die "cannot write $tmp"; }
    chmod 644 "$tmp"
    mv "$tmp" "$CONF" || { rm -f "$tmp"; die "cannot replace $CONF"; }
}

show() {
    gtk=$(gtk_size)
    om_d=$(conf_get omnibox_delta)
    tab_d=$(conf_get tab_delta)
    om_pt=$((gtk + OMNIBOX_OFFSET + om_d))
    tab_pt=$((gtk + TAB_OFFSET + tab_d))
    echo "  config:       $CONF"
    echo "  GTK UI font:  ${gtk}pt   (gtk-font-name in $GTK_INI)"
    echo ""
    echo "  element      delta   effective size            calculation"
    echo "  URL bar      ${om_d}     ${om_pt}pt  ${gtk} + ${OMNIBOX_OFFSET} + ${om_d}"
    echo "  tab strip    ${tab_d}     ${tab_pt}pt  ${gtk} + ${TAB_OFFSET} + ${tab_d}"
    echo ""
    # The device scale factor multiplies these point sizes, so what lands on
    # screen is bigger than the numbers above when DSF > 1.
    dsf=$(grep -ho 'force-device-scale-factor=[0-9.]*' /etc/chromium.d/*.conf 2>/dev/null | head -1)
    dsf=${dsf#*=}
    if [ -n "$dsf" ] && [ "$dsf" != "1" ] && [ "$dsf" != "1.0" ]; then
        om_scr=$(awk -v a="$om_pt" -v s="$dsf" 'BEGIN{printf "%.1f", a*s}')
        tab_scr=$(awk -v a="$tab_pt" -v s="$dsf" 'BEGIN{printf "%.1f", a*s}')
        echo "  device scale: x$dsf (from /etc/chromium.d) multiplies the above:"
        echo "                URL bar ~${om_scr}pt, tabs ~${tab_scr}pt as rendered"
        echo "                (CHROMIUM_UI_SCALE=1.0 in /etc/chromium.d/00-defaults.conf for 1:1)"
        echo ""
    fi
    if [ -x /usr/lib/chromium/chromium ]; then
        echo "  apply by restarting:  chromium   (this build, honours the deltas)"
        echo "                        w          (Google Chrome, ignores them)"
    else
        echo "  NOTE: /usr/lib/chromium/chromium is not installed yet, so nothing"
        echo "        reads these values. Build it: REPO_DIR=... bash steps/chromium.sh"
    fi
}

set_one() {   # $1 = omnibox|tab, $2 = absolute pt or +N/-N delta
    case "$1" in
        omnibox) key=omnibox_delta; offset=$OMNIBOX_OFFSET ;;
        tab)     key=tab_delta;     offset=$TAB_OFFSET ;;
        *) die "unknown element '$1' (use: omnibox | tab)" ;;
    esac
    cur_om=$(conf_get omnibox_delta)
    cur_tab=$(conf_get tab_delta)
    if [ "$key" = "omnibox_delta" ]; then cur=$cur_om; else cur=$cur_tab; fi

    case "$2" in
        +*|-*)
            case "${2#+}" in
                ''|*[!0-9]*) die "not a number: $2" ;;
            esac
            new=$((cur + ${2#+}))
            ;;
        *)
            case "$2" in
                ''|*[!0-9]*) die "not a number: $2 (use 16, +2 or -1)" ;;
            esac
            gtk=$(gtk_size)
            new=$(( $2 - gtk - offset ))
            ;;
    esac

    if [ "$new" -lt "$MIN_DELTA" ] || [ "$new" -gt "$MAX_DELTA" ]; then
        echo "  refused: delta $new would be outside ${MIN_DELTA}..${MAX_DELTA} points" >&2
        echo "  for this element that means an effective size of" >&2
        echo "  $(( $(gtk_size) + offset + MIN_DELTA ))pt..$(( $(gtk_size) + offset + MAX_DELTA ))pt" >&2
        exit 1
    fi

    case "$key" in
        omnibox_delta) conf_write "$new" "$cur_tab" ;;
        tab_delta)     conf_write "$cur_om" "$new" ;;
    esac
    gtk=$(gtk_size)
    echo "  ${key} = ${new}   ->  ${key%%_delta} text $((gtk + offset + new))pt (was $((gtk + offset + cur))pt)"
    echo "  written to $CONF — restart the browser to apply."
    [ "$new" -lt -2 ] || [ "$new" -gt 4 ] && \
        echo "  note: outside the tested -2..+4 range; the tab strip is a fixed height, so watch for clipping." >&2
    exit 0
}

case "${1:-show}" in
    show|"")   show ;;
    reset)     conf_write 0 0; echo "  deltas reset to 0/0 (stock Chromium sizing) — restart the browser." ;;
    omnibox|tab)
        [ $# -eq 2 ] || die "usage: chromium-ui-font $1 <16 | +2 | -1>"
        set_one "$1" "$2"
        ;;
    -h|--help|help)
        sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *) die "unknown command '$1' (try: chromium-ui-font help)" ;;
esac
