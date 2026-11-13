# AGENTS.md — Agent guidelines for this repo

## DESTRUCTIVE ACTIONS ARE FORBIDDEN

**Never** perform any action that intentionally breaks, crashes, kills, or disrupts
a running process, daemon, or application unless the user explicitly asks for it.
This includes:
- Running `node -e` scripts that throw uncaught exceptions
- Killing processes with `kill`, `pkill`, `killall`
- Sending signals (SIGTERM, SIGKILL, SIGHUP, etc.)
- Calling `process.exit()`, `process.report.writeReport()`, or similar
- Simulating crashes to "test" crash reporting
- Any form of fault injection or chaos testing

Verification of fixes should use non-destructive checks: inspect logs, check
config syntax, test with `--help`, check `pgrep`, etc. If a destructive test
is truly needed, ask the user first and get explicit confirmation.

---

# AGENTS.md — Agent guidelines for this repo

## Command output

Always show output streaming live so the user can see progress. Never suppress
stdout/stderr unless explicitly asked. For long-running commands, pipe stderr to
stdout so both streams are visible:

```bash
# GOOD — user sees everything
make -j$(nproc) 2>&1 | tail -30

# BAD — output hidden, user thinks it's stalled
make -j$(nproc) >/dev/null 2>&1
```

## Show the running status of anything you start

Every process started (daemon, server, browser, watcher, long build) must have
its state visible on screen — not only in a log, not only in your summary:

```bash
# on launch  — show the tool's own ready line, or:
pgrep -af voxd
ss -ltnp | grep 8080

# while running — a fresh status line, not an assertion:
pgrep -af voxd && tail -3 /var/log/root-vox.log

# when done — the final state (alive / exited / exit code):
pgrep -x voxd || echo "exited: $?"
```

Never background something with `&` and then declare success from the launch
command alone. Never call a service "ready" or "deployed" without a status check
you actually ran and showed.

## Logging conventions

All project components log to `/var/log/` with a consistent
`<username>-<component>-YYYYMMDD-HHMMSS.log` pattern:

- **Session scripts** (dwm, vpn, wifi-manager, vnc, net-watch): `/var/log/<user>-<component>-YYYYMMDD-HHMMSS.log`
- **Daemons** (voxd): `/var/log/<user>-vox.log` (single file, append-only, `YYYY-MM-DD HH:MM:SS: message` format)
- **System/installer** (bootstrap, post-install-*, steps): `/var/log/<user>-<component>-YYYYMMDD-HHMMSS.log`
- **Toggle scripts** (toggle-bar.sh, toggle-hide-mode.sh): log to stderr (captured by session log) via `log_me()` helper
- **Hide-mode debug** (dwm.c): fprintf(stderr, ...) with `[dwm]` prefix (captured by session log)

The canonical pattern for shell scripts:
```sh
LOG_DIR="/var/log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/${USER:-root}-<component>-$(date +%Y%m%d-%H%M%S).log"
exec >>"$LOG_FILE" 2>&1
```

New C code should use `/var/log/<user>-vox.log` via `getenv("USER")`, NOT hardcoded
`/root/logs/`.

## Installer step discipline

**Every system modification** (building libraries, installing binaries,
deploying models, copying files outside the repo, running `ldconfig`, creating
directories under `/usr/local`, etc.) **MUST** be done through an idempotent
installer step in `steps/`.

Rules:
- One step per subsystem (e.g. `steps/vox-sherpa.sh` for the VOX + sherpa-onnx pipeline)
- Each step must be **idempotent**: running it twice produces the same result
- Steps check for existing artifacts before doing work ("already installed" early-return)
- Never run raw `make install`, `cp`, `ldconfig`, or `systemctl` directly in agent
  tool calls — write the step, then execute the step
- Step naming: `steps/<subsystem>.sh`
- **Fix source files directly** — edit the canonical file under `scripts/`, `dotfiles/`,
  `lib/`, etc., then have the step `cp` it. Never use dynamic patching (sed, Python
  text replacement, marker-based injection) when you can just fix the file in place.

Counter-examples (do NOT do):
```bash
# BAD — raw system modification in agent call
cp ./libfoo.so /usr/local/lib/ && ldconfig

# BAD — not idempotent, redoes work every run
mkdir -p /usr/local/foo && make install
```

Correct pattern:
```bash
# GOOD — write the step script
write: steps/foo.sh  (idempotent, checks for existing install)
# then run it
bash steps/foo.sh
```

## Running steps

All step scripts use `REPO_DIR` to locate repo files. The repo lives at
`/root/Development/slackware-installer-for-rs`. Always set it explicitly when
running steps:

```bash
REPO_DIR=/root/Development/slackware-installer-for-rs bash steps/foo.sh
```

The default fallback in steps is `/root/slackware-installer-for-rs` which does
not exist — running steps without `REPO_DIR` will silently degrade (missing source
files, skipped cp operations).

## Verification before claiming readiness

**Never** claim something is "ready" or "deployed" without verifying it actually
works. For shell scripts: `bash -n` for syntax, then run it. For binaries: execute
with `--help` or a test path. For daemons: check `pgrep`, check logs.

```bash
# MINIMUM before saying "ready":
bash -n scripts/foo.sh              # shell syntax
./voxd --help 2>&1 | head -3         # binary runs
pgrep -x voxd                         # daemon alive
tail -3 /var/log/root-vox.log          # logging works
```


---

# Browser stack — two browsers, do not conflate them

| binary | built by | what it is | launched by |
|---|---|---|---|
| `/opt/google/chrome/chrome` (wrapped as `/usr/local/bin/chrome`) | `steps/chrome.sh` | **Google Chrome**, the DRM baseline | `w`, `wk`, Mod+b |
| `/usr/lib/chromium/chromium` (wrapped as `/usr/bin/chromium`) | `steps/chromium.sh` | **our own Chromium build**: Widevine via Chrome's CDM + URL-bar/tab fonts independently adjustable | `chromium` |

Hard-won facts, do not re-litigate:

* Widevine is **compile-time**. `ungoogled-chromium-bin` (the only Chromium
  Slackware has) is built without it and rejects
  `com.widevine.alpha` with `NotSupportedError` — no flag or CDM copy fixes
  that. That is why we build Chromium ourselves with the switches Debian uses
  (`proprietary_codecs`, `ffmpeg_branding="Chrome"`, `enable_widevine`), and
  why the CDM is copied from Chrome's .deb instead of being built
  (`patches/chromium/README.md` has the licensing reasoning).
* Stock Chromium sizes the URL bar (14pt target) and tab labels (12pt target)
  from one font, with no way to move them separately.
  `patches/chromium/0001-per-element-ui-font-deltas.patch` adds a dedicated
  `CONTEXT_TAB_TITLE` plus runtime deltas from `/etc/chromium/ui-font.conf`,
  tuned by `chromium-ui-font`. Never delete that patch to make a build pass:
  the build is pointless for this machine without it — rebase it instead.
* Page zoom is 200% with the zoom control reading **100%**, because it comes
  from `--force-device-scale-factor=2` in the wrapper (`steps/chrome.sh:`
  section 3), not from Chrome's zoom setting. DSF and the zoom control
  multiply, so the stored zoom stays at 100% (`chrome-default-zoom 100`).
  `dotfiles/chromium/wk` must not seed per-host zoom again — DSF is
  profile-independent and `partition.default_zoom_level` is inert here.

After touching anything under `patches/chromium/`, `dotfiles/chromium/`,
`lib/chromium-version.sh` or `steps/chromium.sh`, run:

```bash
bash tests/chromium-ui-font-parse.sh      # parses the shipped patch, 17 cases, no Chromium tree
REPO_DIR=$PWD bash steps/chromium.sh status
```

Version bumps: follow the checklist in `lib/chromium-version.sh` and the
rebase procedure in `patches/chromium/README.md` (includes the 157 renames
that broke the first attempt). Keep the pin close to the installed Chrome so
the CDM host version still matches.

---

# Mouse cursor — 48 px theme cursors, and dwm/st must not use XC_* glyphs

The panel is 2560x1600 on 288x180 mm (~225 dpi) but X reports 96 dpi, so the
cursor was half-size *and* fixed: dwm and st loaded the server's cursorfont
bitmaps (`XCreateFontCursor(XC_left_ptr)`, measured 9x16 px with
`XFixesGetCursorImage`), which no setting can enlarge — the server does not
link libXcursor. Both now use `XcursorLibraryLoadCursor` (step
`steps/xcursor.sh` for the values, `doc/cursor-size.md` for the measurements).

The size and theme live in exactly one file, `dotfiles/xcursor/xcursor.conf`
(48 px, Adwaita — 2x the 24 px freedesktop default, and one of the theme's
real image sizes 24/30/36/48/72/96). `steps/xcursor.sh` installs it as
`/etc/xcursor.conf` and generates `/etc/X11/xcursor-resources` (xrdb -merge in
dwm-start's xinitrc → `Xcursor.size` for every libXcursor client) and
`/etc/profile.d/xcursor.sh` (env for login shells, `dwm-start` also exports
both). GTK is the exception: once `gtk-cursor-theme-size` is present GTK stops
consulting `Xcursor.size`, so the step rewrites those two keys in each human
user's `gtk-3.0/settings.ini` (`/root`, `/home/*` with uid >= 1000, `/etc/skel`).

A theme name the theme does not have falls back to the small core glyph
*silently* — Adwaita has no `sizing` (dwm's old `XC_sizing`), so dwm asks for
`se-resize`. After touching the conf run `REPO_DIR=$PWD bash steps/xcursor.sh`;
after touching dwm/st cursor code run the matching suckless step (they stamp
`config.mk` too, because `-lXcursor` lives there). A running session keeps the
old cursor until X restarts — dwm loads cursors once at startup.

---

# Screen locking — lid suspends, and slock covers the screen first

Lid close **suspends** (elogind `HandleLidSwitch=suspend`); lid open wakes it.
The old `/etc/acpi/events/lid-close` → `/sbin/poweroff` handler is gone — do not
put it back. `steps/acpi-wakeup.sh` keeps the lid switch enabled as a wake
source for exactly this reason (power button + lid, nothing else).

Hard rule: **nothing may be visible on wake except slock.** That is enforced
mechanically, not by sleeps: `slock` writes `/run/slock.locked` only after its
keyboard/pointer grabs succeed, and `scripts/lock-screen.sh` returns 0 only when
that marker exists and its pid is really slock. The elogind sleep hook
(`/lib64/elogind/system-sleep/10-slock-lock`, `pre` stage) and
`scripts/idle-lock.sh` (locks `IDLE_LOCK_LEAD` seconds before the DPMS blank)
both wait on it before sleeping/blanking. Unlock destroys the covering window
*while the grabs are still held* so no keystroke leaks into the desktop.

`steps/slock.sh` builds slock (`sources/slock`), `xidle` (`sources/xidle`,
MIT-SCREEN-SAVER; nothing in the base system reports idle time) and installs
`/etc/pam.d/slock`. `steps/screen-locking.sh` owns the lid/sleep policy and
installs both sleep hooks (`10-slock-lock`, `20-sleep-log`). Never
`rm /usr/local/bin/slock` (an old version of that step did, silently deleting
the locker on every run). Details and verification: `doc/screen-locking.md`.

**Lid close must resume on lid open — and that means s2idle, not `deep`.**
The machine used to suspend into legacy S3 (`mem_sleep=deep`) and never come
back: `/var/log/messages` ends with `PM: suspend entry (deep)` and the next
line is the next boot, 26 hours later, after a power-button reset (2026-11-12).
The cause was our own wake policy: `power wake restrict` forced `deep` so the
sysfs wakeup restrictions would "bite". This firmware does not implement S3
usefully — it advertises ACPI low-power S0 idle (dmesg: `Low-power S0 idle
used by default for system suspend`), i.e. it wants **s2idle**. Every place
that touches `mem_sleep` (`scripts/power.sh`, `steps/wakeup-power-only.sh`)
now selects s2idle when the kernel offers it. `power set sleep deep` is the
escape hatch for a machine where s2idle is the broken one; do not make it the
default again. `/var/log/<user>-sleep.log` (hook `20-sleep-log`) writes a
`pre` line before sleeping and a `post` line after waking, so "did it come
back?" is answerable from disk after a hard power-off — syslogd is frozen for
the whole suspend, so `/var/log/messages` cannot answer it.

---

# Power button — two-stage hold, three handlers that can race

The button must never power off on a tap. **Three** things can do that on this
machine, and all three had to be dealt with (`steps/powerkey-hold.sh`):

| handler | what it did | now |
|---|---|---|
| `/etc/acpi/acpi_handler.sh` (acpid) | `power) /sbin/init 0` — powered off instantly, independent of elogind. This was the real tap-killer. | `power) :`, original kept as `acpi_handler.sh.orig` |
| elogind | `HandlePowerKey=poweroff` (default) | `HandlePowerKey=ignore` in `/etc/elogind/logind.conf.d/20-powerkey.conf` |
| `powerkey-hold` (new) | — | owns the button now |

`powerkey-hold` measures the hold with a `poll()` timeout (the action fires
*while* held, not on release):

* **2.5 s hold** → `/sbin/shutdown -h now` — orderly: services stop, fs sync and
  unmount. 2.5 s is the requested gesture, and the bar counts up to it and
  names it: `Power button: 1.2 s / 2.5 s = SHUTDOWN`.
* **longer (~5 s)** → the embedded controller cuts power itself; that is the
  system/hardware fallback, and there is no software stage for it (`-T 0`).
  A `-T 10` force-off stage was tried and could never fire: the EC hard-off
  wins first.
* **shorter** → nothing at all (logged, e.g. `released after 0.82 s (< 2.5 s) ignored`).

**Which input device the button appears on is not obvious on this machine.** The
node *named* "Power Button" (`/dev/input/event1`) is **silent**; the press/release
pairs come from **"Intel HID events"**. That is why the first version, which
matched the device by name, never saw a press while `acpid` (ACPI netlink)
happily powered the machine off. The daemon now opens *every* device that
advertises `KEY_POWER` (capability via `EVIOCGBIT`, not the name) and logs the
list at startup:

```
watching 3 device(s) [Intel HID events, AT Translated Set 2 keyboard, Power Button]
```

ACPI netlink only reports the press, never the release, so hold timing **must**
come from evdev.

It ignores SIGTERM/SIGINT/SIGHUP/SIGPIPE on purpose: rc.6 stops processes during
the shutdown it just started, and without that the 10 s escape could never run.
Times are `ARGS="-t 2.5 -T 0"` in `scripts/powerkey-hold-start`, the ONLY place
they are written: `/etc/rc.d/rc.local` and `scripts/dwm-start.sh` both call that
helper, so two thresholds cannot drift apart. Log:
`/var/log/<user>-powerkey.log`. Single instance is a flock on
`/run/powerkey-hold.pid`.

**The daemon must exist in every session.** `rc.local` starts it at boot
(outside any logind session, so it survives X), but Slackware ships
`/etc/rc.d/rc.local` as **0644** while `rc.M` runs it only `if [ -x ]` — every
hook in it was silently dead at boot and the hold count vanished from the bar
after the next reboot (seen 2026-11-13). `steps/powerkey-hold.sh` now chmods
rc.local **after** its own rewrite (the `grep > new && mv` would otherwise
leave 0644), and `scripts/dwm-start.sh` re-runs the start helper on every X
start, so an X restart or a killed daemon cannot lose it either.

Do not "fix" this by putting `HandlePowerKey=poweroff` back, and do not restore
`power) /sbin/init 0`: either one re-introduces instant poweroff on a tap.

**What the user sees while holding.** The daemon itself only updates the
topbar, in 0.1 s steps: `Power button: 0.3 s / 2.5 s = SHUTDOWN`, written to the
session's temp-message files (`status_msg`/`status_end`) so dwm-status draws
it — no console or terminal output while counting. At the threshold it spawns
`/usr/local/bin/powerkey-shutdown-msg` (installed from `scripts/`) and then
`/sbin/shutdown -h now`. That helper emits ONE message, verbatim:
`Shutting Down Now...` — to every terminal via `broadcast` (the same
mechanism Mod+Shift+Q uses for `Exiting Window Manager Now...`), to
`/dev/console` (the VT, ready when X lets go), and to the topbar (temp-msg +
`xsetroot` + `show all 600` on the dwm FIFO so hide mode keeps the bar up).
**All three say exactly the same words** — do not add timestamps or prefixes
to one channel only. dwm's `quit()` does the mirror image for Mod+Shift+Q:
same text to broadcast, `/dev/console` and `stext`, then half a second of
`usleep` before `running = 0` so the bar line can actually be read;
`updatestatus()` returns early while `exiting` so dwm-status cannot wipe it.
The timestamped record of the power event is the daemon's own log
(`/var/log/<user>-powerkey.log`), not the console.

---
---

# Keyboard — Mod is Super, and BOTH Caps Lock and the Copilot key are Mod

`dwm`'s `MODKEY` is `Mod4Mask` (Super). `scripts/dwm-start.sh` re-applies the
keymap at **every** X start (`xmodmap`, plus dwm re-grabs on the resulting
mappingNotify):

| key | keycode | mapping |
|---|---|---|
| Caps Lock | 66 | `Super_L` only — Mod and nothing else |
| Copilot | 201 (evdev `KEY_F23`) | `Super_L` on **both** levels (Mod) |

**Caps Lock has NO lock function on this machine, by decision** (2026-11-13).
With `Caps_Lock` on level 2, `Shift+CapsLock` toggled the lock — and so did
`Copilot+CapsLock`, because the Copilot key's firmware Shift is present in the
state at that moment. The user wants neither ("only Fn+CapsLock, nothing
else"), and Fn+CapsLock **cannot exist**: the AT keyboard does not advertise
`KEY_FN` (checked its capability bitmap), an evdev capture of a real
Fn+CapsLock press produced no event at all, and dmesg shows no unmapped
scancode either — the embedded controller never forwards Fn to the OS. So the
lock is deliberately unbound; if a trigger is ever added back it must not be
Mod+something. `Shift+CapsLock` and `Copilot+CapsLock` were measured to leave
the Lock LED untouched now (`xset q` LED mask stays 00000000).

The lock is switched from the command line instead: **`capslock`**
(`sources/capslock/capslock.c`, installed by `steps/capslock.sh`) —
`capslock` toggles, `capslock on|off` sets, `--help` explains, and it prints
exactly one line, `Capslock On` / `Capslock Off`. It uses `XkbLockModifiers`
on the Lock modifier, not a fake keycode (no keycode produces `Caps_Lock` any
more), so the LED follows. `~/.bashrc` aliases `cl`, `CL` and `CAPSLOCK` to it
(`capslock` is also the short form). `help.sh` lists them on ONE line — put
the single `#help:` marker on the `cl` alias only, or the list grows three.

**The Copilot key's firmware presses Shift and Super itself** (Shift+Super+F23 is
the Microsoft keyboard spec; xkeyboard-config's `PC_SHIFT_SUPER_LEVEL2` type
exists for that chord and *preserves* both modifiers). The Super half is what we
want; the Shift half is poison because dwm grabs keys with **exact** masks:
Mod+X would arrive as Mod+Shift+X (tag instead of view, `quit` for Mod+Shift+Q)
and bindings with no Shift sibling (`Mod+Return`, `Mod+r`, `Mod+h`, ...) would
never reach dwm at all. That is why `sources/copilot-mod/copilot-mod.c` exists
(installed by `steps/copilot-mod.sh`, started from `dwm-start`): it watches the
key with **RECORD** (no grabs, nothing is taken from any client) and drops the
firmware Shift with `XTest` — a fake release, which updates the server's
modifier state exactly like a real one, so the *next* key press matches the
right grab. It asserts Mod4 itself only if the firmware sent none.

Two traps that cost real time here:

* `XRecordInterceptData.data_len` is in **4-byte units**, not bytes (a full
  event is 8). Comparing it to `sizeof(xEvent)` (32) rejects every event and
  the daemon silently does nothing — which is exactly how it shipped first and
  why `Copilot+CapsLock` kept toggling the lock. Measure: press the key and
  check that the modifier state loses Shift (`XQueryPointer` mask 0x41 -> 0x40),
  not just that the process is running.
* RECORD reports the keycode it was given; `XTestFakeKeyEvent` takes **X**
  keycodes (evdev + 8), so a probe must press 201 (F23), not 193.

Do not "simplify" this into an xmodmap-only change: `xmodmap` cannot remove a
modifier the firmware pressed, and XKB `SetMods` only *adds* modifiers (see
`_XkbFilterSetState` in `xkbActions.c` — it sets `setMods`, it does not clear
Shift).

**Hide-mode bar reveals are input-driven — measured, not guessed.** 60 s of
idle with the session untouched produced zero lines in the dwm log, so nothing
reveals itself. The bar is shown by (a) a bare Mod press (`grabkeys()` grabs
bare Super deliberately, "hide-mode temp-bar-reveal"), (b) a Mod *release*
(`keyrelease()` starts a 3 s auto-hide timer) and (c) `focusin()`'s "lost Mod
release" reconciliation, which starts a 3 s reveal too. (c) usually is not a
lost release at all: a normal Mod+Left chord moves focus, `modkeyheld` is
still 1, and the bar is re-revealed for no visible change (44 times in one
session). Before blaming the bar, look at the reason in the session log; and
if (c) is narrowed, check whether Mod is still down (`XkbGetState` mods &
MODKEY) before reconciling — the release path (b) covers the normal case.

"New tag" (a revealed but still empty tag) is the light cell with the dark
number; its glyph is drawn a second time 1 px over with `drw_text_over()` (no
background repaint) so the number reads bolder. `drw.c`/`drw.h` are vendored in
`dotfiles/suckless/dwm/` for exactly that, and `steps/suckless-dwm.sh` stamps
them alongside `dwm.c`/`config.h`.


# Display / kernel — the GPU is `xe`, not `i915`

The internal GPU is Wildcat Lake bound to the **xe** driver
(`xe 0000:00:02.0: [drm] Found pantherlake/wildcatlake (device ID fd80)`).
Every `i915.*` parameter in the elilo append line is therefore inert here —
it exists for the older XPS 13 (i915) the installer also supports. Do not
assume "PSR is already off because `i915.enable_psr=0` is there".

Freezes (picture stops, no cursor, keyboard dead, audio keeps playing) are the
**DSB engine** on pipe A never answering — measured 2026-11-09 with the catcher:

```
[CRTC:151:pipe A] DSB 0 response timeout   (x250 at X start)
kworker+i915_flip state=D wchan=drm_atomic_helper_wait_for_flip_done
  drm_atomic_helper_wait_for_flip_done <- intel_atomic_commit_tail [xe]
```

The fix is `xe.enable_dsb=0` (driver programs display registers from the CPU
instead). It is in every boot entry's append line; PSR stays on (`enable_psr=1`,
PSR2/selective-fetch/panel-replay off). Do **not** diagnose these stalls as PSR
again — PSR idle timeouts and the selective-fetch message are noise here, and
PSR2-off / selective-fetch-off boots still froze.

Evidence gathering (**retired** 2026-11-09): `display-hang-catcher` was the
passive `/dev/kmsg` + `/proc` + `/sys` sampler that produced the DSB proof
above. It is no longer installed, no longer started from `rc.local`, and its
step is gone — the root cause is in the boot config, so nothing needs
watching. Its dumps are kept; reinstall it from git history if a stall ever
needs re-measuring:

```bash
git log --oneline --all -- steps/display-hang-catcher.sh
ls -dt /var/log/*-display-hang-* | head -3     # dumps it left behind
```

Do **not** try to backport `cbe5654759` into 7.2.15: measured, that `xe.ko`
freezes the machine the moment `x` starts (no kernel error at all) while the
stock module is fine; the patch is written for 7.4 and needs its whole series.
A vanilla 7.2.15 build was proven symbol-identical to Slackware's module, so it
is the patch, not the build.

Full evidence, the ABI verification table, fallback profiles (`psr1` keeps
panel self-refresh, `off` is last resort) and post-reboot checks:
`doc/display-freeze.md`.
