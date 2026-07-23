# somebar Hide Mode — Architecture

## Overview

Hide Mode is a feature where the status bar auto-hides after periods of inactivity, temporarily
reappearing on status changes or when the user holds the Mod (Super) key.

## Key files

| File | Role |
|---|---|
| `dotfiles/somebar/bar.cpp` | Bar rendering, transparent/hidden states, exclusive zone |
| `dotfiles/somebar/bar.hpp` | Bar class with `_hidden` flag, `setShown()`, `setExclusive()` |
| `dotfiles/somebar/main.cpp` | FIFO command handling, auto-hide timer, `updatemon()` |
| `scripts/dwl-status.sh` | Status text generation, signal-change detection |
| `scripts/toggle-hide-mode.sh` | Mod+H handler — toggles hide mode ON/OFF |
| `scripts/toggle-bar.sh` | Mod+B handler — toggles bar visibility, kills hide mode |
| `dotfiles/suckless/dwl/dwl.c.patched` | Mod key handler sends `showmod all`/`showmod off` |

## State machine

### Core variables (main.cpp)

| Variable | Purpose |
|---|---|
| `hideMode` | Whether hide mode is ON. Managed by FIFO commands. |
| `modKeyHeld` | True while Mod key is pressed. Blocks auto-hide. |
| `autoShowUntil` | Timestamp for temporary show expiration (0 = no temp show). |
| `mon.desiredVisibility` | Permanent visibility intent. Set only on hide mode changes and Mod+B. |
| `bar._hidden` | Whether bar renders transparent/null buffer (true = hidden). |

### Visibility logic (`updatemon()`)

```
shouldShow = desiredVisibility || (hideMode && autoShowUntil > 0)

if shouldShow:
    if surface exists: setShown(true)   → _hidden=false, re-attach buffer, render
    else:             show(output)      → create surface, exclusive zone=0

else if surface exists:
    hide()  → _hidden=true, attach null buffer (surface becomes invisible)
```

### Exclusive zone logic

Only reserve screen space when bar is PERMANENTLY shown:

```
zone = (!hideMode && desiredVisibility) ? barHeight() : 0
```

Updated in `updatemon()` via `bar.setExclusive(zone)`.

## FIFO commands

| Command | Source | Effect |
|---|---|---|
| `showmod all` | dwl Mod press | `modKeyHeld=true`, `autoShowUntil=0`, `updateVisibility` |
| `showmod off` | dwl Mod release | `modKeyHeld=false`, `autoShowUntil=now+3` |
| `show all` | dwl-status signal changes | In hideMode: `autoShowUntil=now+3`, `setShown(true)` |
|  |  | In !hideMode: `updateVisibility(all, true)` |
| `hide all` | toggle-bar.sh | `autoShowUntil=0`, `updateVisibility(all, false)` |
| `hidemode on` | toggle-hide-mode.sh | `hideMode=true`, `autoShowUntil=0`, `modKeyHeld=false` |
| `hidemode off` | toggle-hide-mode.sh | `hideMode=false`, `autoShowUntil=0`, `modKeyHeld=false` |

## Key design decisions

### 1. Surface is NEVER destroyed after creation

`bar.hide()` does NOT call `_surface.reset()` or `_layerSurface.reset()`.
Instead it attaches a null buffer (`wl_surface_attach(nullptr)`) which makes the
surface invisible while keeping the exclusive zone alive.

**Why:** Destroying and recreating the surface changes the exclusive zone, which
triggers dwl to resize all windows. We want windows to stay at a stable size.

### 2. Temporary shows don't change `desiredVisibility`

In hide mode, temporary shows (signal changes, tag changes, modifier key) only
set `autoShowUntil` and call `setShown(true)`. They NEVER touch `desiredVisibility`.

**Why:** If `desiredVisibility` is toggled during temp shows, the `show` and `hide`
transitions fight within the same event batch — both commits are flushed together
and the compositor only sees the final state.

### 3. `autoShowUntil` is the single auto-hide timer

All temporary shows extend `autoShowUntil = now + 3`. The main poll loop checks
this at the top of each iteration. When it expires, `bar.hide()` is called directly.

**Why:** A single centralized timer prevents race conditions between the dwl-side
fork/sleep timers and the somebar-side poll timer. All background sleep timers
were removed from shell scripts.

### 4. Layer is TOP (was BOTTOM)

The bar surface uses `ZWLR_LAYER_SHELL_V1_LAYER_TOP` so it renders above windows
when temporarily showing in hide mode.

### 5. No frame callbacks for hide

`bar.hide()` directly commits a null buffer via `wl_surface_attach(nullptr)`
and `wl_surface_commit()`. It does NOT use the frame callback pipeline.

### 6. Buffer format is ARGB8888 (was XRGB8888)

Changed to support alpha (transparency). X in XRGB means alpha is ignored.
With ARGB8888, `cairo_set_source_rgba(0,0,0,0)` writes actual alpha=0 pixels.

## `toggle-bar.sh` state tracking

`/tmp/bar_shown` tracks whether the bar is rendering content (not hidden).
Synced by `updatemon()` in main.cpp using `bar.isShown()` (which checks `!_hidden`).

## Debug logging

All components log to stderr (captured in `~/logs/dwl-YYYYMMDD-HHMMSS.log`):
- `[bar]` prefix — bar.cpp rendering and state changes
- `[somebar]` prefix — main.cpp FIFO handling and timers
- dwl-status.sh logs to `~/logs/dwl-status-YYYYMMDD-HHMMSS.log`
