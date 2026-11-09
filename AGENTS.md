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
`/etc/pam.d/slock`. `steps/screen-locking.sh` owns the lid/sleep policy. Never
`rm /usr/local/bin/slock` (an old version of that step did, silently deleting
the locker on every run). Details and verification: `doc/screen-locking.md`.

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

* **3 s hold** → `/sbin/shutdown -h now` — orderly: services stop, fs sync and
  unmount.
* **10 s hold** → `sync()` then `/sbin/poweroff -f` — forces the power off when
  the orderly path is stuck.
* **shorter** → nothing at all (logged).

It ignores SIGTERM/SIGINT/SIGHUP/SIGPIPE on purpose: rc.6 stops processes during
the shutdown it just started, and without that the 10 s escape could never run.
Times are `ARGS="-t 3 -T 10"` in the step. Log: `/var/log/<user>-powerkey.log`.
Single instance is a flock on `/run/powerkey-hold.pid`.

Do not "fix" this by putting `HandlePowerKey=poweroff` back, and do not restore
`power) /sbin/init 0`: either one re-introduces instant poweroff on a tap.

---

# Display / kernel — the GPU is `xe`, not `i915`

The internal GPU is Wildcat Lake bound to the **xe** driver
(`xe 0000:00:02.0: [drm] Found pantherlake/wildcatlake (device ID fd80)`).
Every `i915.*` parameter in the elilo append line is therefore inert here —
it exists for the older XPS 13 (i915) the installer also supports. Do not
assume "PSR is already off because `i915.enable_psr=0` is there".

Fullscreen hi-res video (usually at playback start) sometimes freezes the
session: picture stops, no cursor, keyboard dead, audio keeps playing — on
`flip_done timed out` / `commit wait timed out` on `pipe A`. That message only
says a wait expired; it does not say which one, so **do not disable PSR (or
any other power feature) as a guess**. The default profile of
`steps/gpu-display.sh` is `stock` — it changes nothing.

Evidence gathering is already installed: `display-hang-catcher` (passive;
reads `/dev/kmsg`, `/proc`, `/sys`) dumps every task's kernel stack on a stall
signature, so the next event names the hung function:

```bash
ls -dt /var/log/*-display-hang-* | head -1
ps -o pid,etime,args= -p "$(cat /run/display-hang-catcher.pid)"
/usr/local/bin/display-hang-catcher --dump-now     # on-demand capture
```

Do **not** try to backport `cbe5654759` into 7.2.15 again: measured
2026-11-09, that `xe.ko` freezes the machine the moment `x` starts (no kernel
error at all), while the stock module is fine. The patch is written for 7.4 and
needs its whole series; a vanilla 7.2.15 build was proven symbol-identical to
Slackware's module, so it is the patch, not the build. The recipe and ABI gates
stay in `steps/kernel-xe-psr-fix.sh` for a 7.4.y kernel only.

Current mitigation is the kernel knob, not a disable-everything: profile
`psr1` (`xe.enable_psr=1 xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0`)
keeps panel self-refresh — the actual 0.3–1 W saving — and drops only the
selective-fetch path that fails at boot here and that the missing upstream
fixes address. `steps/gpu-display.sh stock` reverts it.

Full evidence, the ABI verification table, fallback profiles (`psr1` keeps
panel self-refresh, `off` is last resort) and post-reboot checks:
`doc/display-freeze.md`.
