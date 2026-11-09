# Chromium, built here: DRM + independently sized URL bar / tab fonts

Status: the step, the patch and the runtime tooling are in the repo; the build
itself is hours of CPU and is run on purpose, not during a normal install.

| | command | when |
|---|---|---|
| check the machine can build it | `REPO_DIR=$PWD bash steps/chromium.sh preflight` | first time |
| build + install + verify | `REPO_DIR=$PWD bash steps/chromium.sh` | once per version |
| just verify an existing install | `REPO_DIR=$PWD bash steps/chromium.sh verify` | after any change |
| what state am I in? | `REPO_DIR=$PWD bash steps/chromium.sh status` | any time |
| tune the fonts | `chromium-ui-font show` / `chromium-ui-font omnibox 16` | any time, no rebuild |

## Why the installer builds its own Chromium

Widevine support is a **compile-time** property. Slackware ships no Chromium
package; SBo offers `ungoogled-chromium-bin`, built with `enable_widevine=false`
and with the CDM support stripped, so it cannot play DRM video at any
configuration. Measured on this box (`steps/chrome.sh:7-13`):

```
Chromium 154  -> requestMediaKeySystemAccess('com.widevine.alpha')
                 rejects with NotSupportedError
Chrome   157  -> resolves (WIDEVINE_OK)
```

So the build uses the same switches Debian uses for `chromium`:

```
proprietary_codecs = true      # H.264 / AAC
ffmpeg_branding    = "Chrome"  # the branded ffmpeg feature set
enable_widevine    = true      # register the key system
```

…and supplies the CDM the way Debian does: **not built, not redistributed** —
copied out of Google Chrome's .deb (`/opt/google/chrome/WidevineCdm`, installed
by `steps/chrome.sh`) into `/usr/lib/chromium/WidevineCdm`. That is the same
licensing posture as Debian's `chromium` + user-supplied `libwidevinecdm.so`,
and the reason the version pin is kept close to the installed Chrome: the CDM
declares `x-cdm-host-versions: 10,11` and the browser must implement one of
them.

The second reason for building is `patches/chromium/`:
**the URL bar font size and the tab strip font size become independently
adjustable** — see `patches/chromium/README.md` for the whole story. Stock
Chromium (and Google Chrome) tie both to one font and two compiled-in targets
(14pt omnibox, 12pt labels), which is why they look different and cannot be
moved apart.

## What gets installed (Debian layout)

```
/usr/lib/chromium/chromium            the binary
/usr/lib/chromium/*.pak, icudtl.dat   resources, locales/, MEIPreload/
/usr/lib/chromium/WidevineCdm/        CDM copied from Google Chrome
/usr/lib/chromium/VERSION             version + patch fingerprint (idempotency)
/usr/bin/chromium                     wrapper (dotfiles/chromium/chromium-wrapper)
/etc/chromium/ui-font.conf            font deltas (dotfiles/chromium/ui-font.conf)
/etc/chromium.d/*.conf                sourced by the wrapper, Debian-style
/usr/local/bin/chromium-ui-font       font tuning helper
/var/cache/chromium-build/            tarball + ~50 GB source tree + out/Default
```

Google Chrome stays where it is (`/opt/google/chrome`, `/usr/local/bin/chrome`)
and stays the default for `w` / `wk` / `Mod+b`. This build is additive: nothing
is removed, and `steps/chrome.sh` is unaffected.

## Building

```sh
cd /root/Development/slackware-installer-for-rs
REPO_DIR=$PWD bash steps/chromium.sh preflight   # tools, libs, disk, tarball HEAD, gn
REPO_DIR=$PWD bash steps/chromium.sh             # all: fetch → unpack → patch → gen → build → install → verify
```

Expect, on this machine (6 cores / 15 GB RAM / ~385 GB free):

| stage | cost |
|---|---|
| tarball download | ~1.5 GB |
| unpack | 10-20 min, ~50 GB on disk (needs ~50 GB peak with `out/`) |
| `gn gen` | minutes, + a 1-2 GB download for Chromium's pinned clang |
| `ninja chrome` | **hours** (2-6 h at `-j6`); `CHROMIUM_OFFICIAL=1` is much longer |

Every stage is idempotent and resumable: an interrupted build continues from
`out/Default`, and `install`/`verify` are skipped when the marker matches.

`is_official_build` is written by the step: `false` by default (faster, far
less memory — ThinLTO off), `true` with `CHROMIUM_OFFICIAL=1` for a
Debian-like release build.

## Tuning the two font sizes (no rebuild)

```sh
chromium-ui-font                 # what is set now, in effective points
chromium-ui-font omnibox 16      # URL bar text -> 16pt
chromium-ui-font tab 13          # tab labels   -> 13pt
chromium-ui-font tab +1          # relative
chromium-ui-font reset           # back to stock deltas (0/0)
```

Effective size = GTK UI font (`chrome-ui-font` / `~/.config/gtk-3.0/
settings.ini`) + Chromium's offset (URL bar +2, tabs 0) + the delta. With the
installer default font of 12pt: URL bar 14pt, tabs 12pt — which is exactly the
mismatch you see in stock Chromium.

Values are clamped to `-6..+10`; `-2..+4` is the tested range (fixed tab strip
height). A change needs a browser restart: the deltas are read once per
process. The URL bar is also height-clamped by the location bar — pushing the
delta past what fits stops having an effect rather than clipping.

## Page zoom: 200% with the zoom control reading 100%

`w` and `wk` start every tab and every window at 200% without touching Chrome's
zoom setting:

```sh
# /usr/local/bin/chrome (generated by steps/chrome.sh, section 3)
exec /opt/google/chrome/chrome --force-device-scale-factor=2 ...
```

`--force-device-scale-factor` is a browser-wide switch: new tabs, new windows
and `wk`'s throwaway profile all inherit it, and Chrome's zoom control still
shows **100%**. That is the "zoom from another control" the machine is set up
for.

Two consequences:

* **The two zoom factors multiply.** Zoom a site to 125% and it renders at
  `2.0 × 1.25 = 250%`. Keep the stored zoom at 100%
  (`chrome-default-zoom 100`, applied by `steps/chrome.sh`).
* **DSF scales the UI too.** URL bar text, tab labels and toolbar grow with the
  page. On Google Chrome the only counter-lever is the GTK UI font
  (`chrome-ui-font 11`). On this locally built Chromium the fonts are
  separately tunable (`chromium-ui-font`), which is the point of the build.

`wk` no longer seeds per-host zoom into its throwaway profile: DSF is
profile-independent, so a fresh profile renders identically. Do not reintroduce
zoom seeding there (`partition.default_zoom_level` is inert in this Chrome
build; that is why the old code had to pin per-host entries).

The `chromium` wrapper mirrors the same 200% by default
(`/etc/chromium.d/00-defaults.conf`). Set `CHROMIUM_UI_SCALE=1.0` there to get
true 100% pages with the font deltas untouched — useful when you want to see
exactly what a font delta does.

## Bumping the version

`lib/chromium-version.sh` holds the pin and the ordered checklist. In short:

```sh
# 1. edit CHROMIUM_VERSION in lib/chromium-version.sh
# 2. rebase the patches
REPO_DIR=$PWD bash steps/chromium.sh rebase
# 3. parser regression test (no Chromium tree needed)
bash tests/chromium-ui-font-parse.sh
# 4. build / install / verify
REPO_DIR=$PWD bash steps/chromium.sh build install verify
```

If `rebase` rejects a hunk, the procedure — including how to fetch a single
upstream file to diff against — is in `patches/chromium/README.md`. Two real
renames from the 157 bump are listed there; expect that kind of move, not
"the feature was removed".

Keep the version close to the installed Google Chrome so the CDM handshake
stays valid.

## Troubleshooting

| symptom | cause / fix |
|---|---|
| `gn gen` fails on `third_party/llvm-build` | Chromium's pinned clang is missing: `python3 tools/clang/scripts/update.py` in the source tree |
| `gn gen` complains about `LASTCHANGE` | `python3 build/util/lastchange.py -o build/util/LASTCHANGE` |
| `gn gen` complains about an **unknown argument** | an arg in `lib/chromium-gn-args.gn` was removed upstream; check `gn args --list` |
| build OOM-killed | lower `CHROMIUM_JOBS`, keep `is_official_build=false` |
| `verify` says the config path is missing from the binary | the patch did not apply/compile — `steps/chromium.sh patch` and read `patches/chromium/README.md` |
| EME probe says `WIDEVINE_FAIL` | no CDM in `/usr/lib/chromium/WidevineCdm` (install Chrome first), or the CDM is too old/new for this build |
| fonts did not change after `chromium-ui-font` | browser still running (deltas are read once per process), or you are looking at Google Chrome, which ignores the file |
| tab labels clipped | delta outside `-2..+4`; the tab strip height is fixed |

## Do not

* Revert to `ungoogled-chromium-bin` "to simplify" — it cannot do DRM at all.
* Ship or redistribute `libwidevinecdm.so` — it is copied locally from the
  Chrome .deb and must stay that way.
* Delete or rewrite `patches/chromium/` to make a build pass. The build is
  worthless for this machine without the font feature; rebase instead, and let
  `steps/chromium.sh verify` and `tests/chromium-ui-font-parse.sh` decide.
