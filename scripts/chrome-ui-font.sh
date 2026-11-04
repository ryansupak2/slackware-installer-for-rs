#!/bin/sh
# chrome-ui-font <pt> — set the GTK UI font size used by Chrome's URL bar, tab
# labels and dialogs (also honoured by every other GTK app).
#
# Page/HTML content is NOT affected by this: that is CHROME_UI_SCALE (device
# scale factor) plus Chrome's own per-site zoom.
#
# Usage:  chrome-ui-font 14      then reopen Chrome
#         chrome-ui-font         show the current value

CUR=$(sed -n 's/^gtk-font-name=Berkeley Mono \(.*\)/\1/p' "${HOME}/.config/gtk-3.0/settings.ini" 2>/dev/null | head -1)

if [ $# -eq 0 ]; then
    echo "  current UI font size: Berkeley Mono ${CUR:-unknown}"
    echo "  set with: chrome-ui-font <pt>   (then reopen Chrome)"
    exit 0
fi

case "$1" in
    ''|*[!0-9]*) echo "usage: chrome-ui-font <pt>  (integer, e.g. 14)"; exit 1 ;;
esac

changed=0
for f in "${HOME}/.config/gtk-3.0/settings.ini" /root/.config/gtk-3.0/settings.ini /etc/skel/.config/gtk-3.0/settings.ini; do
    [ -f "$f" ] || continue
    sed -i "s/^gtk-font-name=.*/gtk-font-name=Berkeley Mono $1/" "$f" 2>/dev/null && changed=1
done

if [ "$changed" -eq 1 ]; then
    echo "  UI font -> Berkeley Mono $1 (was ${CUR:-unknown})"
    echo "  Reopen Chrome (w) for the URL bar / tab labels to use it."
else
    echo "  ERROR: no gtk-3.0/settings.ini found — run steps/chrome.sh"
    exit 1
fi
