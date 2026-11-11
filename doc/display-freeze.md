# Display stalls on fullscreen hi-res video — evidence, not guesses

## Symptom

Rare. Usually **when starting playback** of a hi-res video fullscreen in
Chrome: the picture stops moving, no mouse cursor, keyboard dead — but audio
keeps playing. Only a killed X server or a reboot brings it back. Three
occurrences so far (2026‑11‑06 20:44, 2026‑11‑09 13:17, and the PSR‑idle
episodes on 11‑03/11‑04).

## What the logs actually prove

Every occurrence ends with a display atomic commit that never completed:

```
Nov  9 13:17:05 kernel: xe 0000:00:02.0: [drm] *ERROR* [CRTC:151:pipe A] flip_done timed out
Nov  9 13:17:31 kernel: xe 0000:00:02.0: [drm] *ERROR* flip_done timed out
Nov  9 13:17:31 kernel: xe 0000:00:02.0: [drm] *ERROR* [CRTC:151:pipe A] commit wait timed out
Nov  9 13:17:41 kernel: xe 0000:00:02.0: [drm] *ERROR* [PLANE:35:plane 1A] commit wait timed out
```

"flip_done timed out" says *a wait expired*, not *which* wait. The same message
is produced by PSR‑exit, DSB, FBC and DPT paths alike.

Circumstantial, and weaker than it looks:

```
boot, every time:  xe 0000:00:02.0: [drm] Selective fetch area calculation failed in pipe A
Nov 3/4:           xe 0000:00:02.0: [drm] *ERROR* Timed out waiting for PSR Idle for re-enable
```

Those PSR lines are from **earlier boots**, not from the seconds before the
freezes. So PSR is a suspect, not a proven cause. That is why this repo does
**not** turn PSR off by default: it is a working power feature (≈0.3–1 W of
idle saving on this panel) and disabling it on a guess is how real bugs get
hidden.

Hardware, for reference: Wildcat Lake, display version `30.02 A00`, GPU bound
to **xe** (`xe 0000:00:02.0: [drm] Found pantherlake/wildcatlake`), eDP
2560x1600@120, Chrome at `--force-device-scale-factor=2` (composites
5120x3200). `i915.*` parameters in the cmdline are inert here.

## ROOT CAUSE FOUND (2026-11-09): the DSB engine stops responding

`display-hang-catcher` caught the stall live, and the kernel stack names the
wait — no guessing left:

```
xe 0000:00:02.0: [drm] *ERROR* [CRTC:151:pipe A] DSB 0 response timeout
   …that line repeated 249 times ("last message buffered 249 times")…
xe 0000:00:02.0: [drm] *ERROR* [CRTC:151:pipe A] DSB 0 poll error

kworker/u28:0+i915_flip  state=D  wchan=drm_atomic_helper_wait_for_flip_done
  drm_atomic_helper_wait_for_flip_done+0x5b/0xb0 [drm_kms_helper]
  intel_atomic_commit_tail+0xfbb/0x1b70 [xe]
```

DSB is the *display state buffer*: a hardware unit the driver feeds so it can
program display registers (plane updates, PSR exit) without the CPU. On this
display (Wildcat Lake, `30.02 A00`) **DSB 0 never answers**. Every atomic commit
that used it then waits for a flip-done that can never arrive, in
`intel_atomic_commit_tail` — which is exactly the "picture frozen, no cursor,
keyboard dead, audio still playing" symptom: the commit worker is stuck, X
cannot present, input is never drained, audio is a separate subsystem.

Note what this means for the earlier hypotheses: the PSR idle timeouts and the
selective-fetch message were **noise**, not the cause. The freeze happens with
PSR2 off, with selective fetch off, and (in the 7.4 attempts) right after
`xe_init` returns — all consistent with the DSB path, which every commit uses.

## The fix: `xe.enable_dsb=0`

With DSB disabled the driver programs display registers from the CPU (the
documented fallback). Cost is a little CPU/power for display updates; PSR and
the rest of the power features stay enabled.

Every boot entry now carries it (`steps/gpu-display.sh`, `steps/kernel-7.4.sh`):

```
xe.enable_dsb=0 xe.enable_psr=1 xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0
```

Verify after a boot:

```bash
cat /sys/module/xe/parameters/enable_dsb     # 0
dmesg | grep -c 'DSB'                        # 0 (was ~250 per X start)
```

## History: hypotheses that were tested and ruled out

### `cbe5654759` backported into `xe.ko`## Prime suspect, found upstream

Selective fetch keeps a per-plane "dirty area" in the atomic plane state. In
this kernel that area is **not cleared when plane state is duplicated**, so a
new plane state can inherit a stale area and the driver programs a selective
update for a region that no longer exists — exactly the situation created when
a new video surface appears at playback start. Upstream fix:

| commit | title | in 7.2.15 | in 7.3.3 | in 7.4‑rc2 |
|---|---|---|---|---|
| `cbe5654759` | `drm/i915/psr: Clear selective fetch area when duplicating plane state` | **no** | **no** | yes |

Its three sibling fixes *are* backported to this kernel (verified by marker
grep on the tagged sources): `b56721c32e` (linked plane sel fetch),
`94cb1f08b1` (enabled pipe planes in state), `a4c0e7f804` (stale sel fetch
enable bits). `cbe5654759` carries no `Cc: stable` tag, so it will not arrive
in 7.2.y/7.3.y by itself.

Note the display code lives in `drivers/gpu/drm/i915/display/` and is built
into **xe.ko** (`CONFIG_DRM_XE=m`, `CONFIG_DRM_XE_DISPLAY=y`) — so a backport
means rebuilding one module, not the whole kernel.

## The collector that produced this evidence (retired)

`display-hang-catcher` was a passive sampler (reads `/dev/kmsg`, `/proc`,
`/sys`; no sysrq, no signals, no resets) started from `/etc/rc.d/rc.local` by
`steps/display-hang-catcher.sh`. On a stall signature (`flip_done timed out`,
`commit wait timed out`, `Timed out waiting for PSR Idle`, DSB, `GPU HANG`)
it wrote one directory per stall, and `display-waits.txt` named the hung
function (`intel_dsb_wait` here):

```
/var/log/<user>-display-hang-YYYYMMDD-HHMMSS-N/
    dmesg.txt          full kernel ring with timestamps
    tasks.txt          every task: state, wchan, kernel stack, cmdline
    display-waits.txt  the graphics-relevant subset  <-- read this first
    drm-sysfs.txt      connector status / enabled / dpms
    xrandr.txt         modes and properties
    parameters.txt     xe/i915 module parameters actually in force
```

It is **removed** (2026-11-09). With the DSB root cause fixed in the boot
config there is nothing left to watch, and its own runs cost more than they
returned. Nothing is installed, `rc.local` no longer starts it, both
`steps/display-hang-catcher.sh` and `scripts/display-hang-catcher.sh` are
deleted, and `post-install-global.sh` no longer calls the step. The dumps it
did capture are kept and still stand as the evidence for `xe.enable_dsb=0`:

```bash
ls -d /var/log/*-display-hang-*
grep -E 'intel_psr|intel_dsb|intel_fbc|drm_atomic_commit' \
    /var/log/*-display-hang-*/display-waits.txt
```

To reinstate it, restore both files from git history
(`git log --oneline --all -- steps/display-hang-catcher.sh`) and run the step.

## Tried: `cbe5654759` backported into `xe.ko` — REGRESSES X START, do not use on 7.2.15

`steps/kernel-xe-psr-fix.sh` built and installed a `xe.ko` with that commit
applied (it applies cleanly to 7.2.15, ~20 lines). It loaded fine, booted fine,
and then **froze the machine as soon as `x` was started**:

```
14:13:59  Xorg: glamor EGL ok · TearFree: enabled · screen size set · 2560x1600
14:14:00  Xorg: Input(s) initialized            <- X fully up
14:14:09  Xorg: input devices removed           <- server tearing down
          (no kernel message at all: no flip_done, no PSR timeout, no GT reset)
```

One-variable A/B, because nothing else differed between the two boots:

| boot | module | started `x` | result |
|---|---|---|---|
| 13:18 | stock | yes | worked, 54 min up |
| 14:13 | backported | yes | froze at first frames |
| 14:20 | stock (rolled back) | yes | works |

Build hygiene was ruled out: rebuilding `xe.ko` from unpatched 7.2.15 source
with the same config produces a module that is **symbol-for-symbol identical to
Slackware's** (3947 symbols, all sizes equal), so the regression is the patch,
not the toolchain.

Why it breaks: `cbe5654759` is written against the 7.4 tree. Applied alone to
7.2.15 it clears the selective-fetch area on plane-state duplication and relies
on the surrounding 7.4 code to rebuild it consistently ("Ned to ensure
consistent selective fetch area on full update"). Without that context the SU
area can be programmed inconsistently, and the first atomic commits of an X
start are exactly where that bites. A partial backport of a *coherent series* is
not a fix.

**Status: `xe.ko` is stock again**; the step remains in the repo, with the recipe
and ABI gates, for when a 7.4.y kernel is available (drop the patch step and the
issue disappears, because 7.4 has the whole series).

## Current setting: `psr1` profile (kernel-level, keeps the power feature)

```
xe.enable_psr=1 xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0
```

Applied by `steps/gpu-display.sh psr1`. Panel self-refresh — the part that
actually saves the 0.3–1 W on a static screen — stays **on**; what is switched
off is exactly the code path that (a) fails at boot on this panel
(`Selective fetch area calculation failed in pipe A`), (b) is the subject of the
missing upstream fixes, and (c) is what the backport touched when it broke X.

Selective fetch only helps *partial* damage frames, so this is the narrowest
supported knob that removes the suspect path. Revert with:

```bash
REPO_DIR=$PWD bash steps/gpu-display.sh stock     # back to kernel defaults
REPO_DIR=$PWD bash steps/gpu-display.sh psr1      # this profile
```

## The real fix needs the whole series: a 7.4.y kernel

`cbe5654759` and its context exist only from 7.4 on (`v7.4-rc2` verified). When
7.4.y ships, the options are: install a 7.4 kernel (Slackware -current will
package it), or build it as a **second elilo entry** so the working 7.2.15
entry stays as a fallback. At that point delete `xe.enable_psr=1` again — with
the complete series, PSR2/selective fetch can come back.

## Fix options, in order

1. **Backport `cbe5654759`** onto 7.2.15 and rebuild `xe.ko` (needs the 7.2.15
   source tree and `/boot/config-7.2.15.x64`; the patch touches ≈20 lines in
   `intel_psr.c` + `intel_plane.c`). Narrow, reversible, keeps every power
   feature.
2. **Move to a 7.4.y kernel** once it is a stable release (7.4‑rc2 already has
   the fix; 7.3.3 does not).
3. **If the collector shows a non-PSR wait** (DSB/FBC/DPT), apply the matching
   knob instead — one at a time, with the collector still running.

## Fallback profiles (deliberate, not default)

`steps/gpu-display.sh` owns the xe knobs on the cmdline and defaults to
`stock` (= change nothing):

```bash
REPO_DIR=$PWD bash steps/gpu-display.sh              # stock: no overrides (default)
REPO_DIR=$PWD bash steps/gpu-display.sh psr1         # keep PSR1, drop PSR2/sel-fetch
REPO_DIR=$PWD bash steps/gpu-display.sh off          # PSR off (last resort)
EXTRA="xe.enable_fbc=0" REPO_DIR=$PWD bash steps/gpu-display.sh   # add one knob
```

`psr1` is the honest middle ground if a stall happens and you need relief
before the kernel fix: panel self-refresh (the part that saves the 0.3–1 W)
stays on, only the selective-fetch path that failed at boot is dropped.

## If a stall happens anyway

No new dumps are produced any more (the collector is retired), so read the
kernel ring and the X log directly:

```bash
# what hung: DSB timeouts at X start are the known signature of this box
dmesg -T | grep -E 'DSB .*timeout|flip_done|commit wait|intel_(psr|fbc)' | tail -30
grep -E 'DSB|flip_done|commit wait' /var/log/Xorg.0.log | tail -20
# the dumps captured while the collector was still running:
ls -dt /var/log/*-display-hang-* 2>/dev/null | head -1
# recovery, from a VT (Ctrl+Alt+F2):
#   restart X; if the VT switch also hangs, Alt+SysRq+E, I, S, U, B
```
