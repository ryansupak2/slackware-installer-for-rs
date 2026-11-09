#!/bin/sh
# chrome-default-zoom <percent> — set Chrome's OWN page zoom for the root
# profile (and normalise any per-host zoom entries to the same value).
#
# This is NOT where the machine's 150% comes from. The wrapper
# /usr/local/bin/chrome starts Chrome with --force-device-scale-factor=1.5,
# which makes pages render at 150% while this zoom control stays at 100% —
# that is the point: the user sees "100%" in the zoom control and the zoom
# comes from the DSF switch (steps/chrome.sh, section 3).
#
# Leave it at 100% unless a site needs its own zoom: the two multiply, so
# 125% here is 187.5% on screen.
#
# Chrome stores zoom as log(zoom) / log(1.2) in Default/Preferences under
# "partition". It rewrites that file when it exits, so Chrome MUST be closed.
#
# Usage:  chrome-default-zoom           show the current values
#         chrome-default-zoom 100       back to "no stored zoom" (the default)
#         chrome-default-zoom 125       store 125% for every site (187.5% on screen)

set -u
PREFS=/root/.config/google-chrome/Default/Preferences

show() {
    python3 - "$PREFS" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
part = d.get("partition", {})
dz = part.get("default_zoom_level")
print("  default zoom:", f"{1.2**dz:.1%}" if isinstance(dz, (int, float)) else "browser default (100%)")
for host, hosts in (part.get("per_host_zoom_levels") or {}).items():
    for h, rec in (hosts or {}).items():
        if isinstance(rec, dict) and isinstance(rec.get("zoom_level"), (int, float)):
            print(f"    {h}: {1.2**rec['zoom_level']:.1%}")
PYEOF
}

if [ ! -f "$PREFS" ]; then
    echo "  ERROR: no Chrome profile at $PREFS (start Chrome once first)"
    exit 1
fi

if [ $# -eq 0 ]; then
    echo "  Chrome page zoom for /root:"
    show
    echo "  set with: chrome-default-zoom 100   (keep at 100: DSF 1.5 already gives 150%)"
    exit 0
fi

PCT=$1
case "$PCT" in
    ''|*[!0-9]*) echo "usage: chrome-default-zoom <percent, e.g. 100>"; exit 1 ;;
esac
if awk -v p="$PCT" 'BEGIN{exit !(p >= 25 && p <= 500)}'; then :; else
    echo "  percent must be between 25 and 500"; exit 1
fi

if pgrep -f '/opt/google/chrome/chrome ' >/dev/null 2>&1; then
    echo "  ERROR: Chrome is running. Close every Chrome window first —"
    echo "         Chrome writes Default/Preferences on exit and would undo this."
    exit 1
fi

BACKUP="$PREFS.bak-$(date +%Y%m%d-%H%M%S)"
cp -a "$PREFS" "$BACKUP" || { echo "  ERROR: cannot back up $PREFS"; exit 1; }
echo "  backup: $BACKUP"

python3 - "$PREFS" "$PCT" <<'PYEOF'
import json, math, sys
prefs, pct = sys.argv[1], float(sys.argv[2])
level = math.log(pct / 100.0) / math.log(1.2)   # Chrome's log base 1.2 encoding
d = json.load(open(prefs))
part = d.setdefault("partition", {})
part["default_zoom_level"] = level
n = 0
for host, hosts in (part.get("per_host_zoom_levels") or {}).items():
    for h, rec in (hosts or {}).items():
        if isinstance(rec, dict) and "zoom_level" in rec:
            rec["zoom_level"] = level
            n += 1
json.dump(d, open(prefs, "w"))
print(f"  default zoom -> {pct:.0f}%  (per-site entries normalised: {n})")
PYEOF

echo "  Reopen Chrome: new tabs and sites now open at ${PCT}%."
echo "  (Per-site values set later in a tab still win for that host.)"
