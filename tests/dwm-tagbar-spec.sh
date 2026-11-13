#!/bin/bash
# tests/dwm-tagbar-spec.sh — the bar's tag drawing rules, checked on the source
#
# The tags are dynamic in this build: a tag is only drawn while it has windows
# (or is the anchor tag 1, or has just been revealed and is still empty). The
# appearance rules that follow from that, and that are easy to undo by accident
# when rebasing dwm, are asserted here:
#
#   1. OCCUPIED tags carry NO extra mark. The old little box next to every tag
#      with a window is gone; the tag being visible already says it is occupied.
#   2. The SELECTED tag has two looks, and only two:
#        a) it has windows -> hollow foreground-coloured box on the normal
#           (black) tag background, tag colours not inverted;
#        b) it is a revealed but still EMPTY tag (a fresh blank tag held
#           open until something is created in it) -> inverted colours:
#           light background, dark glyph. That is the whole indicator; there
#           is no asterisk or other extra mark any more.
#   3. Nothing else inverts: urgent tags used to be drawn inverted and now
#      simply get no special mark.
#   4. No fill in the bar paints the empty space with the foreground colour:
#      the empty title area must be cleared with ColBg (`1, 1`), because
#      `1, 0` fills that whole area with ColFg and turns the empty bar light.
#
#
#
# Plus a real syntax check of dwm.c when the X11 headers are available (that is
# what catches a bad edit before `make` does).
#
# Run: bash tests/dwm-tagbar-spec.sh

set -u

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO_DIR/dotfiles/suckless/dwm/dwm.c"
CFG="$REPO_DIR/dotfiles/suckless/dwm/config.h"
for f in "$SRC" "$CFG"; do
    [ -f "$f" ] || { echo "FATAL: $f not found"; exit 1; }
done

PASS=0
FAIL=0
check() {   # $1 description, $2 expected, $3 actual
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"
        PASS=$((PASS + 1))
    else
        printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1))
    fi
}
check_has() {       # $1 description, $2 literal, $3 haystack
    case "$3" in
        *"$2"*) check "$1" "yes" "yes" ;;
        *)      check "$1" "yes" "no" ;;
    esac
}
check_lacks() {     # $1 description, $2 literal, $3 haystack
    case "$3" in
        *"$2"*) check "$1" "absent" "present" ;;
        *)      check "$1" "absent" "absent" ;;
    esac
}

# drawbar() body only: the rules must not be satisfied by some other function.
DRAWBAR=$(awk '/^drawbar\(Monitor \*m\)/ { f = 1 }
               f && /^}/ { print; exit }
               f { print }' "$SRC")
[ -n "$DRAWBAR" ] || { echo "FATAL: could not extract drawbar() from $SRC"; exit 1; }


echo "*****************************************************"
echo "DWM TAG BAR SPEC (occupied / blank / selected)"
echo "*****************************************************"
echo "source: $SRC"
echo ""

# ------------------------------------------------------------------
echo "1. Occupied tags carry no extra mark"
check_lacks "no per-occupied-tag box"     "occ & 1 << i)" "$DRAWBAR"
check_lacks "no urgency variable in the bar" "urg |=" "$DRAWBAR"
check_lacks "no urgency mask in the bar"     "urg &"  "$DRAWBAR"
check_has  "occupancy is still computed"  "occ |= c->tags;" "$DRAWBAR"

# ------------------------------------------------------------------
echo ""
echo "2. The selected tag with windows: hollow box, normal background"
check_has "that case uses SchemeSel" \
    "scheme[i == m->curtagidx ? SchemeSel : SchemeNorm]" "$DRAWBAR"
check_has "the tag text is not inverted" \
    "drw_text(drw, x, 0, w, bh, taglpad(tags[i], w), tags[i], 0);" "$DRAWBAR"
check_has "the hollow box is drawn for it" \
    "drw_rect(drw, x, 0, w, bh - 1, 0, 0);" "$DRAWBAR"
check_has "the box is skipped when the tag is empty" \
    "if (i == m->curtagidx && !blank)" "$DRAWBAR"

# ------------------------------------------------------------------
echo ""
echo "3. The selected tag while empty: inverted chip, no extra mark"
check_has "emptiness is decided as 'current and not occupied'" \
    "blank = i == m->curtagidx && !(occ & (1 << i));" "$DRAWBAR"
check_has "the empty selected tag uses the inverted scheme" \
    "if (blank)" "$DRAWBAR"
check_has "...which is SchemeTagSel" \
    "drw_setscheme(drw, scheme[SchemeTagSel]);" "$DRAWBAR"
check_has "SchemeTagSel is in the enum" \
    "enum { SchemeNorm, SchemeSel, SchemeTagSel };" "$(cat "$SRC")"
check_has "SchemeTagSel is inverted (dark fg, light bg) in config.h" \
    "[SchemeTagSel] = { col_gray1, \"#ffffff\", \"#ffffff\" }," "$(cat "$CFG")"
check_lacks "the asterisk helper is gone" \
    "drawblanktagmark" "$(cat "$SRC")"
check_lacks "nothing is drawn with XDrawLines any more" \
    "XDrawLines" "$(cat "$SRC")"

# ------------------------------------------------------------------
echo ""
echo "4. No fill in the bar paints the empty space with the text colour"
check_has "the empty title area is cleared with ColBg" \
    "drw_rect(drw, x, 0, w, bh, 1, 1);" "$DRAWBAR"
check_lacks "nothing fills the empty area with ColFg" \
    "drw_rect(drw, x, 0, w, bh, 1, 0);" "$DRAWBAR"

echo ""
echo "5. The tag squares do not move; only the glyph inside them centres"
check_has "the cell is still the bar height wide" \
    "w = bh;  /* square tags: width = bar height */" "$DRAWBAR"
check_has "the cells still advance by exactly their width" \
    "x += w;" "$DRAWBAR"
check_has "the hollow box still starts at the cell edge" \
    "drw_rect(drw, x, 0, w, bh - 1, 0, 0);" "$DRAWBAR"
check_has "the tag text uses the centring pad" \
    "drw_text(drw, x, 0, w, bh, taglpad(tags[i], w), tags[i], 0);" "$DRAWBAR"
check_lacks "it is no longer left-aligned with lrpad/2" \
    "lrpad / 2, tags[i]" "$DRAWBAR"
check_has "taglpad() computes the glyph width without lrpad" \
    "unsigned int gw = TEXTW(tag) - lrpad;" "$(cat "$SRC")"
check_has "...and returns half the leftover space" \
    "return gw < cellw ? (cellw - gw) / 2 : 0;" "$(cat "$SRC")"

# ------------------------------------------------------------------
echo ""
echo "6. Mod+Shift+Q notice: one text in terminals, console and topbar"
quitfn=$(awk '/^quit\(const Arg \*arg\)/ { f = 1 }
               f && /^}/ { print; exit }
               f { print }' "$SRC")
[ -n "$quitfn" ] || { echo "FATAL: could not extract quit() from $SRC"; exit 1; }
check_has "the exit text is the broadcast text" \
    'Exiting Window Manager Now...' "$quitfn"
check_has "it is broadcast to every terminal" \
    "broadcast 'Exiting Window Manager Now...'" "$quitfn"
check_has "the console VT gets the same words" \
    'fopen("/dev/console"' "$quitfn"
check_has "the topbar gets the same words" \
    'snprintf(stext, sizeof(stext), "%s", notice);' "$quitfn"
check_has "the bar is revealed if hide mode hid it" \
    'autoshowuntil = time(NULL) + 2;' "$quitfn"
check_has "it is drawn and flushed before exiting" \
    'XSync(dpy, False);' "$quitfn"
check_has "it stays up long enough to read" \
    'usleep(EXIT_NOTICE_US);' "$quitfn"
check "the exit notice is half a second" "#define EXIT_NOTICE_US 500000" \
    "$(grep '^#define EXIT_NOTICE_US' "$SRC")"
check_has "a second quit does not restart the notice" \
    'if (exiting)' "$quitfn"
check_has "status updates cannot wipe the notice" \
    'if (exiting)' "$(awk '/^updatestatus\(void\)/ { f = 1 }
                           f && /^}/ { print; exit }
                           f { print }' "$SRC")"
check_has "the notice flag exists" 'static int exiting = 0;' "$(cat "$SRC")"

# ------------------------------------------------------------------
echo ""
echo "7. It still compiles (skipped when the X11 headers are missing)"
if [ -f /usr/include/X11/Xlib.h ] && command -v cc >/dev/null 2>&1; then
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/dwm-spec-XXXXXX") || exit 1
    trap 'rm -rf "$WORK"' EXIT
    cp "$CFG" "$WORK/config.h"
    cp "$SRC" "$WORK/dwm.c"
    # drw.h/util.h belong to the upstream tree, not this repo: use the real
    # ones when the build tree is present, otherwise the minimal ABI we use.
    for h in drw.h util.h; do
        if [ -f "/usr/local/src/suckless/dwm/$h" ]; then
            cp "/usr/local/src/suckless/dwm/$h" "$WORK/$h"
        fi
    done
    if [ ! -f "$WORK/drw.h" ]; then
        cat > "$WORK/drw.h" <<'DRWH'
#include <X11/Xlib.h>
#include <X11/Xft/Xft.h>
#include <fontconfig/fontconfig.h>
typedef struct { Cursor cursor; } Cur;
typedef struct Fnt { Display *dpy; unsigned int h; XftFont *xfont; FcPattern *pattern; struct Fnt *next; } Fnt;
enum { ColFg, ColBg, ColBorder };
typedef XftColor Clr;
typedef struct { unsigned int w, h; Display *dpy; int screen; Window root; Drawable drawable; GC gc; Clr *scheme; Fnt *fonts; } Drw;
Drw *drw_create(Display *, int, Window, unsigned int, unsigned int);
void drw_resize(Drw *, unsigned int, unsigned int);
void drw_free(Drw *);
Fnt *drw_fontset_create(Drw *, const char *[], size_t);
void drw_fontset_free(Fnt *);
unsigned int drw_fontset_getwidth(Drw *, const char *);
unsigned int drw_fontset_getwidth_clamp(Drw *, const char *, unsigned int);
void drw_font_getexts(Fnt *, const char *, unsigned int, unsigned int *, unsigned int *);
void drw_clr_create(Drw *, Clr *, const char *);
Clr *drw_scm_create(Drw *, const char *[], size_t);
Cur *drw_cur_create(Drw *, int);
void drw_cur_free(Drw *, Cur *);
void drw_setfontset(Drw *, Fnt *);
void drw_setscheme(Drw *, Clr *);
void drw_rect(Drw *, int, int, unsigned int, unsigned int, int, int);
int drw_text(Drw *, int, int, unsigned int, unsigned int, unsigned int, const char *, int);
void drw_map(Drw *, Window, int, int, unsigned int, unsigned int);
DRWH
    fi
    [ -f "$WORK/util.h" ] || printf 'void die(const char *fmt, ...);\n' > "$WORK/util.h"

    out=$(cd "$WORK" && cc -fsyntax-only -std=c99 -pedantic -Wall \
        -Wno-deprecated-declarations -I/usr/include/X11 -I/usr/include/freetype2 \
        -D_DEFAULT_SOURCE -D_BSD_SOURCE -D_XOPEN_SOURCE=700L -DVERSION='"spec"' \
        -DXINERAMA dwm.c 2>&1)
    check "dwm.c parses cleanly, no warnings" "" "$out"
    [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/       /'
else
    echo "  skip (no X11 development headers)"
fi

# ------------------------------------------------------------------
echo ""
echo "*****************************************************"
echo "RESULT: $PASS passed, $FAIL failed"
echo "*****************************************************"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
