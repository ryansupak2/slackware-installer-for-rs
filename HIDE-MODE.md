# DWM Bar Hide Mode — Architecture

## Overview

Hide Mode is a feature where the status bar auto-hides after periods of inactivity, temporarily
reappearing on status changes or when the user holds the Mod (Super) key.

## Key files

| File | Role |
|---|---|
| `dotfiles/suckless/dwm/dwm.c` | Hide mode state machine, FIFO handling, bar visibility |
| `scripts/dwm-status.sh` | Status text generation, signal-change detection |
| `scripts/toggle-hide-mode.sh` | Mod+H handler — toggles hide mode ON/OFF |
| `scripts/toggle-bar.sh` | Mod+B handler — toggles bar visibility, kills hide mode |

## State machine

### Core variables (dwm.c)

| Variable | Purpose |
|---|---|
| `hidemode` | Whether hide mode is ON. Toggled by Mod+H / FIFO commands. |
| `modkeyheld` | True while Mod key is pressed. Blocks auto-hide. |
| `autoshowuntil` | Timestamp for temporary show expiration (0 = no temp show). |
| `showbar` | Per-monitor bar visibility flag. |

### Visibility logic (`updatebarvisibility()`)

```
shouldshow = (hidemode && (modkeyheld || autoshowuntil > now)) || (!hidemode && showbar)

if shouldshow:
    show bar on monitor
else:
    hide bar (set bar height to 0)
```

### Exclusive zone

When hidden, the bar height is set to 0, returning screen space to windows.
When shown (permanent or temporary), the bar reclaims its normal height.

## FIFO commands

| Command | Source | Effect |
|---|---|---|
| `show all` | dwm-status signal changes | In hideMode: `autoshowuntil=now+3`, show bar |
| | | In !hideMode: restore bar on all monitors |
| `hide all` | toggle-bar.sh | `autoshowuntil=0`, hide bar on all monitors |
| `hidemode on` | toggle-hide-mode.sh | `hidemode=true`, hide bar, create hide_mode file |
| `hidemode off` | toggle-hide-mode.sh | `hidemode=false`, show bar, remove hide_mode file |

## Key design decisions

### 1. No surface destruction

Unlike somebar/Wayland, dwm controls bar visibility by changing the bar height to 0.
Windows are resized to fill the reclaimed space. No surfaces are created or destroyed.

### 2. Temporary shows don't change permanent visibility

In hide mode, temporary shows (signal changes, tag changes, modifier key) only
set `autoshowuntil`. They NEVER touch `showbar`. When `autoshowuntil` expires,
the bar auto-hides again.

### 3. Mod key reveals bar

Holding the Mod (Super) key sets `modkeyheld=true` which forces the bar visible.
On release, `autoshowuntil` is set to `now+3` for a brief grace period.

### 4. `toggle-bar.sh` state tracking

`$XDG_RUNTIME_DIR/dwm_bar_shown` tracks whether the bar is rendering content.
Synced by `updatebarvisibility()` in dwm.c.

## Debug logging

All components log to stderr (captured in the dwm session log):
- `[dwm]` prefix — dwm.c keypresses, FIFO handling, hide mode transitions
- dwm-status.sh logs to `/var/log/sessions/<user>-dwm-status-YYYYMMDD-HHMMSS.log`
