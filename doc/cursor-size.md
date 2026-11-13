# Mouse cursor size (system-wide, all users)

## Symptom

The cursor was "roughly half the size it should be" — and on the desktop and in
terminals it was worse than that: a 9x16 arrow on a 2560x1600 panel.

## Measurement (before)

The panel is 2560x1600 on 288x180 mm, i.e. ~225 dpi, but X reports 96 dpi
(`xdpyinfo`: `resolution: 96x96 dots per inch`, because there is no DPI
configured). Everything drawn at "1 px = 1/96 inch" therefore lands at ~43% of
its physical size. The cursor was additionally *fixed* size, because dwm and st
asked the server for cursorfont glyphs:

```c
cursor[CurNormal] = drw_cur_create(drw, XC_left_ptr);   /* dwm */
cursor = XCreateFontCursor(xw.dpy, mouseshape);         /* st */
```

Those are bitmaps compiled into the X server. `XFixesGetCursorImage` on the live
session reported:

```
xfixes cursor: 9x16 hotspot 4,8 serial 5
```

There is no server-side knob for them (the server does not link libXcursor), so
no `Xcursor.size`, `XCURSOR_SIZE` or GTK setting could change them. Meanwhile
`/usr/share/icons/Adwaita/cursors/left_ptr` ships real artwork at 24, 30, 36,
48, 72 and 96 px.

## What was changed

1. **dwm and st load theme cursors through libXcursor**
   (`dotfiles/suckless/dwm/drw.c`, `dwm.c`, `config.mk`;
   `dotfiles/suckless/st/x.c`, `config.h`, `config.mk`):

   ```c
   cur->cursor = XcursorLibraryLoadCursor(drw->dpy, "left_ptr");
   ```

   with a `XCreateFontCursor` fallback. Sizes come from libXcursor —
   `XCURSOR_SIZE`/`XCURSOR_THEME` in the environment, or the `Xcursor.size`/
   `Xcursor.theme` X resources — so the cursor is 48 px artwork, not an upscale.

2. **One place holds the values**: `dotfiles/xcursor/xcursor.conf`
   (`XCURSOR_THEME=Adwaita`, `XCURSOR_SIZE=48`). `steps/xcursor.sh` installs it
   as `/etc/xcursor.conf` and generates:

   | file | who reads it |
   |---|---|
   | `/etc/X11/xcursor-resources` | `xrdb -merge` in dwm-start's xinitrc → `Xcursor.size` for every libXcursor client (dwm, st, GTK, Chrome, Qt) |
   | `/etc/profile.d/xcursor.sh` | login shells → `XCURSOR_SIZE`/`XCURSOR_THEME` for clients started outside dwm-start |
   | `<home>/.config/gtk-3.0/settings.ini` | GTK: `gtk-cursor-theme-size` / `gtk-cursor-theme-name` (only those two keys are rewritten) |

   `scripts/dwm-start.sh` additionally exports `XCURSOR_THEME`/`XCURSOR_SIZE`
   for the session it starts.

3. **48, not an arbitrary number**: it is 2× the 24 px freedesktop default (the
   reported "half size") and one of the theme's real image sizes. Keep it on
   the 24/30/36/48/72/96 grid or the image gets resampled.

## Verified

On an isolated `Xvfb` display (the live session was not touched; a new client
measures the image the server actually displays via `XFixesGetCursorImage`):

```
libXcursor: theme=Adwaita size=48 (from the resource DB)

cursor left_ptr   48x48 px     (dwm: root + bar)
cursor se-resize  48x48 px     (dwm: resize corner)
cursor fleur      48x48 px     (dwm: move)
cursor xterm      48x48 px     (st: I-beam)

-- control: size forced back to 24 --
cursor left_ptr   24x24 px
cursor xterm      24x24 px
```

Both resolution paths were measured separately: the root resource database
(`xrdb -merge /etc/X11/xcursor-resources`, no env) and the exported
environment (`XCURSOR_THEME=Adwaita XCURSOR_SIZE=48`, no resources).

`ldd /usr/local/bin/dwm /usr/local/bin/st` show `libXcursor.so.1`, and the theme
names are embedded in both binaries.

**The running session keeps its old cursor until X is restarted** — dwm loads
its cursors once at startup.

## Changing the size

```sh
$EDITOR dotfiles/xcursor/xcursor.conf     # XCURSOR_SIZE=...
REPO_DIR=$PWD bash steps/xcursor.sh
# then restart X (Mod+Shift+Q, startx)
```

## Trap: a missing theme name is silently small

`XcursorLibraryLoadCursor` does not fail for a name the theme lacks — it falls
back to the server's core glyph, which is exactly the small bitmap this whole
change is about. Adwaita has `left_ptr`, `fleur` and `xterm`, but **no
`sizing`** (the cursorfont name dwm used), so dwm asks for `se-resize`.
