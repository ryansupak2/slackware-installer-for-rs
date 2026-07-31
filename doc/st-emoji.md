# st (suckless terminal) — Emoji Handling

## Current state

**Monochrome emojis with full coverage.** Symbola provides vector-outline
monochrome emoji glyphs for essentially all Unicode emoji codepoints.
Color emoji fonts (Noto Color Emoji) are removed from the fontconfig
fallback chain and blocked at the st level via `FC_COLOR=FcFalse`.

### Files involved

| File | Change |
|------|--------|
| `dotfiles/suckless/st/x.c:1353` | `FcPatternAddBool(fcpattern, FC_COLOR, FcFalse)` — blocks color fonts |
| `dotfiles/suckless/st/x.c:1134-1138` | `BadLength` X11 error handler (crash fix, unchanged) |
| `dotfiles/configs/99-berkeley-mono-fallback.conf` | Symbola added, Noto Color Emoji removed |
| `steps/symbola-font.sh` | Extracts Symbola.otf from PDF via `pdfdetach`, installs to `/usr/share/fonts/OTF/` |
| `steps/suckless-st.sh` | Builds st with patched x.c |
| `steps/additional-fonts.sh` | Deploys fontconfig fallback config |

### Font fallback chain

When st requests **Berkeley Mono** and the primary font lacks a glyph:

| Priority | Font | Purpose |
|----------|------|---------|
| 1 | Berkeley Mono | Primary text |
| 2 | DejaVu Sans Mono | Box-drawing, some symbols |
| 3 | Noto Sans Mono | Additional coverage |
| 4 | Noto Sans CJK JP | CJK characters |
| 5 | **Symbola** | Emoji (complete monochrome) |
| 6 | monospace | Last resort |

Noto Color Emoji is excluded from the chain entirely. `FC_COLOR=FcFalse` in
st provides a second line of defense against any accidentally-installed
color bitmap fonts.

### Emoji coverage

All tested emojis render — including 🎉 (U+1F389) and 🔥 (U+1F525) which
DejaVu Sans was missing. Symbola covers essentially all Unicode emoji
codepoints.

### Crash safety

Two layers of protection against the X11 `BadLength` crash:

1. **Fontconfig filter** (`FC_COLOR=FcFalse`): Color bitmap fonts are never
   matched in the fallback path, so their oversized (136×128) glyphs never
   enter the rendering pipeline.

2. **X11 error handler** (lines 1134-1138): If an oversized glyph somehow
   slips through and exceeds the X11 protocol's max request size, the error
   is suppressed instead of crashing st.

3. **Oversized glyph replacement** (lines 1387-1401): Any glyph with extent
   >300px in either dimension is replaced with `U+FFFD`. With Symbola's
   outline glyphs, this never triggers — it's dead code acting as a safety net.

## Why not color emojis?

Color emoji fonts like Noto Color Emoji use embedded PNG bitmaps at a single
strike size (136×128 pixels). These exceed the X11 protocol's max request
size when uploaded via `RenderAddGlyphs`, causing `BadLength`.

Approaches tried:
- **FC_PIXEL_SIZE**: Font won't scale bitmap strikes.
- **FreeType + XPutImage**: Raw Xlib drawing doesn't work from st's draw context.
- **Pre-baked scaled font**: CBDT/CBLC parsing for v3.0 proved non-trivial.

The cleanest path to color emojis in the future is to finish the pre-baked
scaled font tool (`scripts/build-scaled-emoji-font.py`) and install the
resulting font in place of Symbola.

## Deploying changes

```bash
# Install Symbola font (if not already)
REPO_DIR=/root/Development/slackware-installer-for-rs bash steps/symbola-font.sh

# Deploy fontconfig + rebuild st
REPO_DIR=/root/Development/slackware-installer-for-rs bash steps/additional-fonts.sh
REPO_DIR=/root/Development/slackware-installer-for-rs bash steps/suckless-st.sh
```
