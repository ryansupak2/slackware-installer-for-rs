#!/bin/sh
# chrome-default-zoom <percent> — set Chrome's DEFAULT page zoom (what new
# tabs/sites open at) for the root profile, and normalise any existing
# per-site zoom entries to the same value.
#
# Chrome stores zoom as log(zoom) / log(1.2) in Default/Preferences under
# "partition". It rewrites that file when it exits, so Chrome MUST be closed.
#
# Usage:  chrome-default-zoom           show the current values
#         chrome-default-zoom 125       default 125% for every site

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
    echo "  set with: chrome-default-zoom 125"
    exit 0
fi

PCT=$1
case "$PCT" in
    ''|*[!0-9]*) echo "usage: chrome-default-zoom <percent, e.g. 125>"; exit 1 ;;
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
