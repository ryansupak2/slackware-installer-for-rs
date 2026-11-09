# Chromium patches — read this before rebasing anything

The locally built Chromium (`steps/chromium.sh`) is stock upstream **plus**
the patches in this directory. Everything here exists for one feature:

> The URL bar font size and the tab strip font size must be adjustable
> **independently**, at runtime, without rebuilding the browser.

Stock Chromium cannot do that, and it is worth understanding why before
"simplifying" this away.

## Why the two sizes cannot be separated upstream

Both come from one source font (the GTK `gtk-font-name`), through
`ChromeTypographyProvider::GetFontDetailsImpl()`:

| element | context | size |
|---|---|---|
| URL bar | `CONTEXT_OMNIBOX_PRIMARY` | 14pt target, clamped by the location bar height (`ApplyCommonFontStyles` → `GetFontSizeDeltaBoundedByAvailableHeight`) |
| tab strip | `CONTEXT_LABEL` (a plain `views::Label` in `TabTitle`) | 12pt target (`kDefaultSize`) |

Two different compiled-in targets, one shared input, no pref / flag / switch.
`--force-device-scale-factor` and `gtk-font-name` move **both**, keeping the
ratio. So the delta has to be added in code. That is this patch.

## What the patch changes (invariants — keep all five)

`0001-per-element-ui-font-deltas.patch`

1. `ui/views/style/typography.h`
   New `views::style::CONTEXT_TAB_TITLE`, inserted before
   `VIEWS_TEXT_CONTEXT_END`. Must stay < `TEXT_CONTEXT_MAX` (0x1000).
2. `chrome/browser/ui/views/chrome_typography.h`
   `namespace chrome_ui_font { int OmniboxDelta(); int TabDelta(); }`.
3. `chrome/browser/ui/views/chrome_typography.cc`
   The config parser, **wrapped in
   `// BEGIN chrome-ui-font-parser` / `// END chrome-ui-font-parser`
   markers**. `tests/chromium-ui-font-parse.sh` extracts that block and
   compiles it against stubs; if the markers disappear the test fails — that
   is the alarm, not an accident.
   The parser must stay dependency-light: `<algorithm> <cstdlib> <string>
   <string_view>` plus `base/files/file_util.h`,
   `base/strings/string_number_conversions.h`,
   `base/strings/string_split.h`, `base/strings/string_util.h`. Those come in
   transitively as public deps of `//ui/views`; adding anything else risks
   `gn check` failures in `//chrome/browser/ui/views:layout_provider_impl`.
4. `chrome/browser/ui/views/chrome_typography_provider.cc`
   The `switch (context)` that adds `chrome_ui_font::OmniboxDelta()` to
   `CONTEXT_OMNIBOX_PRIMARY` / `CONTEXT_OMNIBOX_POPUP` and
   `chrome_ui_font::TabDelta()` to `CONTEXT_TAB_TITLE`, applied **last** so a
   user value wins over the built-in target.
5. `chrome/browser/ui/views/tabs/tab/tab_title.cc`
   `SetTextContext(views::style::CONTEXT_TAB_TITLE);` in the `TabTitle`
   constructor, plus `#include "ui/views/style/typography.h"`.
   Note: `tab_title.cc` lives in `//chrome/browser/ui/views/tabs/tab:impl`,
   which depends on `//ui/views` but **not** on `//chrome/browser/ui/views`.
   That is why the context lives in the `//ui` enum and not in
   `ChromeTextContext` — do not "tidy" it into the chrome enum without adding
   the dependency (and risking a cycle).

Zero-config behaviour: no `/etc/chromium/ui-font.conf` → both deltas are 0 →
byte-for-byte stock rendering. Keep that property; it is what makes the patch
safe to carry.

## Data flow

```
/etc/chromium/ui-font.conf   (override path: $CHROMIUM_UI_FONT_CONF)
        │  omnibox_delta=N   tab_delta=N      clamp -6..+10
        ▼
chrome_ui_font::LoadDeltas()      static, ONCE per process
        ▼
ChromeTypographyProvider::GetFontDetailsImpl()
        ▼
URL bar text (omnibox)                    tab strip labels (TabTitle)
GTK font + 2pt + omnibox_delta            GTK font + 0pt + tab_delta
```

Written by `scripts/chromium-ui-font.sh` (installed as
`/usr/local/bin/chromium-ui-font`); template in
`dotfiles/chromium/ui-font.conf`. `chromium-ui-font show` prints the effective
point sizes and warns when they leave the sane range.

## Bumping the Chromium version

```sh
# 1. pin the new version
$EDITOR lib/chromium-version.sh            # CHROMIUM_VERSION=...

# 2. try to re-apply
REPO_DIR=$PWD bash steps/chromium.sh rebase

# 3. if a patch rejects, fetch the moved file and rebase by hand
curl -s "https://chromium.googlesource.com/chromium/src/+/refs/tags/$TAG/PATH?format=TEXT" | base64 -d
# (replace PATH with the file named in the .rej, e.g.
#  chrome/browser/ui/views/chrome_typography_provider.cc)

# 4. prove the parser still behaves and the patch is coherent
bash tests/chromium-ui-font-parse.sh
REPO_DIR=$PWD bash steps/chromium.sh status

# 5. build / install / verify
REPO_DIR=$PWD bash steps/chromium.sh build install verify
```

Real drift seen between versions (expect this class of breakage):

* 157: `ui/views/style/typography.cc` was renamed to
  `typography_provider.cc`; the base `TextContext` enum lost every
  Chrome-specific context.
* 157: tab titles moved into a new `TabTitle : views::Label` class
  (`chrome/browser/ui/views/tabs/tab/tab_title.cc`); before that the label was
  constructed inline in `tab.cc`.
* The omnibox size comes from `ApplyCommonFontStyles()` in
  `chrome_typography.cc`; if that moves, only the `+delta` site has to move
  with it — the parser block is independent.

Rules that keep this cheap to rebase:

* keep the hunks **small and separate** — no reformatting, no renames, no
  upstream-style "while I'm here" edits;
* keep every `LOCAL PATCH (slackware-installer-for-rs)` comment: they are the
  grep target (`grep -rn "LOCAL PATCH" patches/chromium/`) and the reason a
  future agent can tell our code from upstream;
* never add a new file to the patch if an already-compiled translation unit
  can host the code (new files need `BUILD.gn` surgery, which is the most
  fragile thing to rebase).

## Verifying without a browser build

```sh
bash tests/chromium-ui-font-parse.sh                 # 17 parser cases
bash tests/chromium-ui-font-parse.sh --conf FILE     # what would the browser read?
git apply -p1 --check patches/chromium/*.patch       # inside a pristine tree
```

After a real build, `steps/chromium.sh verify` proves the feature is inside
the binary:

```sh
strings /usr/lib/chromium/chromium | grep /etc/chromium/ui-font.conf
strings /usr/lib/chromium/chromium | grep -x omnibox_delta
strings /usr/lib/chromium/chromium | grep -x tab_delta
```

If those strings are missing, the patch did not compile in — the build will
still "work", and the font feature will silently be absent. That is exactly
why `verify` fails hard on it.

## Things that are not bugs

* **Clamped URL bar growth.** `CONTEXT_OMNIBOX_PRIMARY` is height-bounded by
  `LocationBarView::GetAvailableTextHeight()`. Past that point the size stops
  growing; raise the UI scale (`--force-device-scale-factor`) if you need more
  room.
* **Clipped tab labels at large deltas.** The tab strip is a fixed ~34px.
  `-2..+4` is the tested range; `chromium-ui-font` warns outside it.
* **A change needs a browser restart.** Deltas are read once per process
  (the Views font cache is built at startup).
* **Only the local build honours the file.** Google Chrome (`/usr/local/bin/
  chrome`) is a prebuilt binary; it ignores `/etc/chromium/ui-font.conf`
  entirely.
