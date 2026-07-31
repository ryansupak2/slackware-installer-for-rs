# st (suckless terminal) — Emoji Handling

## Current state

**Monochrome emojis only.** Color emoji fonts (Noto Color Emoji) are excluded
via `FC_COLOR=FcFalse` in the fontconfig fallback path. DejaVu Sans provides
monochrome emoji glyphs for most common codepoints.

### Files involved

| File | Change |
|------|--------|
| `dotfiles/suckless/st/x.c:1353` | `FcPatternAddBool(fcpattern, FC_COLOR, FcFalse);` |
| `dotfiles/suckless/st/x.c:1134-1138` | `BadLength` X11 error handler (crash fix, unchanged) |
| `steps/suckless-st.sh` | Builds st with our patched x.c |
| `steps/suckless-dwm.sh` | Also builds st (same patches) |

### What the changes do

**`FC_COLOR=False` (line 1353):** When st's primary font (Berkeley Mono) doesn't have
a glyph, fontconfig searches fallback fonts. This line tells fontconfig to skip
color bitmap fonts (Noto Color Emoji) and match outline fonts instead (DejaVu Sans).
DejaVu Sans has monochrome vector emoji glyphs at normal sizes — no X11 protocol issues.

**`BadLength` handler (lines 1134-1138):** Original crash fix. If any oversized glyph
slips through and exceeds the X11 protocol's maximum request size, the X server sends
a `BadLength` error on `RenderAddGlyphs` (minor code 20). Our handler suppresses this
error instead of crashing. The glyph won't render, but st stays alive.

**Oversized glyph replacement (lines 1386-1401):** Original safety net. If a fallback
font's glyph extent exceeds 300×300 pixels (typical for color emoji bitmaps), it's
replaced with `U+FFFD` (replacement character). With `FC_COLOR=False`, this block is
effectively dead code — DejaVu Sans glyphs are all normal-sized vector outlines.

### Emoji coverage

| Char | Codepoint | Renders? | Source |
|------|-----------|----------|--------|
| 😀 | U+1F600 | ✅ | DejaVu Sans |
| 👍 | U+1F44D | ✅ | DejaVu Sans |
| 💯 | U+1F4AF | ✅ | DejaVu Sans |
| 🎉 | U+1F389 | ❌ | No monochrome font has it |
| 🔥 | U+1F525 | ❌ | No monochrome font has it |

To fill the gaps, install a more complete monochrome emoji font (Symbola, etc.)
via a new installer step and add it to the fontconfig fallback chain in
`dotfiles/configs/99-berkeley-mono-fallback.conf`.

## Why not color emojis?

Color emoji fonts (Noto Color Emoji) use embedded PNG bitmaps (CBDT/CBLC tables)
at a single strike size: 136×128 pixels. These bitmaps don't scale — they always
report their native extent.

When Xft tries to upload a 136×128 ARGB32 glyph to the X server via
`RenderAddGlyphs`, the request can exceed the X11 protocol's maximum request size
(~256KB). The X server sends `BadLength`. Without the error handler (line 1134),
st crashes. With the handler, the glyph silently fails to render (blank).

### Approaches tried and abandoned

1. **FC_PIXEL_SIZE constraint:** Adding `FC_PIXEL_SIZE=win.ch` to the fontconfig
   pattern doesn't help — Noto Color Emoji only has one bitmap strike and won't
   scale to arbitrary pixel sizes.

2. **FreeType + XPutImage client-side rendering:** Rendered emoji glyphs via
   FreeType at native size, box-filter scaled to cell size, then XPutImage to
   display. Failed because raw Xlib drawing (XPutImage, XFillRectangle) doesn't
   work from within st's draw context — Xft/XRender state interferes.

3. **FreeType + XRender composite:** Same approach but used `XRenderComposite`
   with `PictOpOver` for alpha blending. Same failure — raw Xlib/XRender calls
   from within the Xft draw context produce no visible output.

4. **Pre-baked scaled font:** A Python script (`scripts/build-scaled-emoji-font.py`)
   was written to parse NotoColorEmoji.ttf's CBDT/CBLC tables, scale each PNG
   glyph to cell height, and write a new TTF. The CBDT/CBLC parsing for v3.0
   format proved non-trivial and the approach was abandoned in favor of
   monochrome support.

### How to add color emoji support in the future

The cleanest path is option 4 above — pre-bake a scaled color emoji font:

1. Finish the CBDT/CBLC parser in `scripts/build-scaled-emoji-font.py`
2. Run it during install to produce a `/usr/share/fonts/TTF/ScaledEmoji.ttf`
3. Add `ScaledEmoji` to the fontconfig fallback chain
4. Remove `FC_COLOR=FcFalse` from x.c
5. The scaled font's glyph bitmaps will be cell-sized → no BadLength → color
   emojis render via the normal Xft path

## Deploying changes

All changes deploy through installer steps:

```bash
REPO_DIR=/root/Development/slackware-installer-for-rs bash steps/suckless-st.sh
```

The step clones st 0.9.2 from suckless.org, copies our patched x.c/config.h/st.h
over it, builds, and installs to `/usr/local/bin/st`.
