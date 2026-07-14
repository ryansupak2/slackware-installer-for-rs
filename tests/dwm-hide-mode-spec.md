# DWM Hide Mode — State Machine Specification & Test Suite

## Overview

This document defines the expected behavior of dwm's hide mode (bar auto-show/hide)
and serves as the specification for the test suite in `dwm-hide-mode-test.c`.

## State Variables

| Variable | Type | Description |
|---|---|---|
| `hidemode` | int (bool) | Hide mode active. Toggled by Mod+H or FIFO `hidemode on/off`. Defaults OFF (0). |
| `modkeyheld` | int (bool) | Super key currently physically held. Tracks Mod key state. |
| `autoshowuntil` | time_t | Timestamp when temporary bar show expires. 0 = no temp show active. |
| `showbar` | bool (per monitor) | Whether bar is visible on this monitor. |

## Input Events

### Keyboard events (simulated as function calls)

1. **`key_press_bare_super()`** — User presses Super_L/Super_R with NO other keys held.
   - ev->state has NO Mod4Mask, keysym = XK_Super_L or XK_Super_R
   - This maps to: KeyPress Super_L state=0x00

2. **`key_release_bare_super()`** — User releases Super_L/Super_R (was bare press, no chord keys pressed in between).
   - ev->state has NO Mod4Mask (the Super key itself was the only modifier)

3. **`key_press_chord(keysym)`** — User presses a regular key WHILE holding Super.
   - ev->state HAS Mod4Mask, keysym = whatever (h, Return, Left, etc.)
   - The Super KeyPress already happened (modkeyheld=1, bar already shown if hidemode)

4. **`key_press_regular(keysym)`** — User presses any key WITHOUT Super held.
   - ev->state has NO Mod4Mask. Triggers reconciliation if modkeyheld is stuck.

5. **`key_release_super_after_chord()`** — User releases Super after a chord sequence.
   - ev->state HAS Mod4Mask (because Super was still held when the chord key was released).
   - **CRITICAL**: In the real X11 implementation, if the bare Super grab was for modifier=0,
     this KeyRelease has state=Mod4Mask and may NOT match the grab, causing a LOST event.

6. **`key_release_super_after_bare()`** — User releases Super after a bare press (no chord).
   - ev->state has NO Mod4Mask. Matches the grab. Normal path.

### FIFO commands (simulated as function calls)

7. **`fifo_show_all()`** — "show all" written to FIFO by dwm-status on signal changes.
8. **`fifo_hidemode_on()`** — "hidemode on" written by toggle-hide-mode.sh.
9. **`fifo_hidemode_off()`** — "hidemode off" written by toggle-hide-mode.sh.
10. **`fifo_hide_all()`** — "hide all" written by toggle-bar.sh.

### Direct function calls

11. **`togglehidemode()`** — Mod+H keybinding. Toggles hidemode.
12. **`togglebar()`** — Mod+B keybinding. Toggles bar visibility, exits hide mode.

### Timer

13. **`timer_tick(seconds)`** — Advances time by N seconds. The event loop checks
    `autoshowuntil` expiry every ~1 second via select() timeout.

---

## State Transition Rules (extracted from dwm.c)

### keypress handler

```
keypress(keysym, state):
    # 1. Reconciliation: lost Mod release
    if (state has NO Mod4Mask) AND modkeyheld:
        modkeyheld = 0
        if hidemode:
            autoshowuntil = now + 3
            updatebarvisibility()
        else:
            autoshowuntil = 0

    # 2. Chord handler: ANY key with Mod held temp-shows bar
    if (state HAS Mod4Mask) AND hidemode AND (NOT modkeyheld):
        modkeyheld = 1
        autoshowuntil = 0
        showbar = 1 on all monitors

    # 3. Keybinding matching (not modeled here)

    # 4. Bare Super press (only if keysym not consumed by binding)
    if keysym == Super_L OR keysym == Super_R:
        if (state has NO Mod4Mask) AND (NOT modkeyheld):
            modkeyheld = 1
            autoshowuntil = 0
            if hidemode:
                showbar = 1 on all monitors
```

### keyrelease handler

```
keyrelease(keysym, state):
    if keysym == Super_L OR keysym == Super_R:
        if modkeyheld:
            modkeyheld = 0
            if hidemode:
                autoshowuntil = now + 3
                updatebarvisibility()
        else:
            # "Mod RELEASE ignored (modkeyheld already 0)"
            # No state change — release was lost/ignored

    else:
        # Reconciliation: non-Super key released without Mod4Mask
        if (state has NO Mod4Mask) AND modkeyheld:
            modkeyheld = 0
            if hidemode:
                autoshowuntil = now + 3
                updatebarvisibility()
            else:
                autoshowuntil = 0
```

### togglehidemode()

```
togglehidemode():
    hidemode = NOT hidemode

    if hidemode (turning ON):
        modkeyheld = 0
        autoshowuntil = 0
        showbar = 0 on all monitors

    else (turning OFF):
        # modkeyheld NOT reset
        showbar = 1 on all monitors
```

### togglebar()

```
togglebar():
    if hidemode:
        hidemode = 0       # exit hide mode
        autoshowuntil = 0
        modkeyheld = 0

    showbar = NOT showbar on selected monitor
```

### FIFO "show all"

```
fifo_show_all():
    if hidemode:
        autoshowuntil = now + 3
        updatebarvisibility()
    else:
        # not in hide mode: restore bars (if not manually hidden)
        showbar = 1 on all monitors (if bar was not manually hidden)
```

### FIFO "hidemode on"

```
fifo_hidemode_on():
    if NOT hidemode:
        hidemode = 1
        autoshowuntil = 0
        modkeyheld = 0
        showbar = 0 on all monitors
```

### FIFO "hidemode off"

```
fifo_hidemode_off():
    if hidemode:
        hidemode = 0
        autoshowuntil = 0
        modkeyheld = 0
        showbar = 1 on all monitors
```

### FIFO "hide all"

```
fifo_hide_all():
    showbar = 0 on all monitors
    # does NOT change hidemode
```

### updatebarvisibility() — called on timer/release

```
updatebarvisibility():
    if NOT hidemode:
        return  # never auto-hide when hide mode is OFF

    shouldshow = modkeyheld OR (autoshowuntil > 0 AND now < autoshowuntil)
    showbar = shouldshow on all monitors
    # NOTE: does NOT call arrange() — windows don't resize on temp show/hide
```

### Timer check (in event loop)

```
every ~1 second (select timeout):
    if autoshowuntil > 0 AND now >= autoshowuntil:
        autoshowuntil = 0
        if hidemode AND NOT modkeyheld:
            updatebarvisibility()
```

---

## Test Scenarios

### 1. Bare Super press/release (hide mode ON)

**Setup**: hidemode=1, modkeyheld=0, autoshowuntil=0, showbar=0
**Events**: key_press_bare_super → key_release_bare_super → timer_tick(4)
**Expected**:
- After press: modkeyheld=1, showbar=1, autoshowuntil=0
- After release: modkeyheld=0, autoshowuntil=now+3, showbar=1
- After 4s timer: autoshowuntil=0, showbar=0

### 2. Mod+H to toggle hide mode OFF (bar permanently shown)

**Setup**: hidemode=1, modkeyheld=0, autoshowuntil=0, showbar=0
**Events**: key_press_bare_super → key_press_chord(XK_h) [triggers togglehidemode ON→OFF] → key_release_super_after_chord
**Expected**:
- After chord: hidemode=0, showbar=1, modkeyheld=0 (reset by togglehidemode ON path... wait, OFF path doesn't reset!)
  - CORRECTION: togglehidemode OFF does NOT reset modkeyheld. But chord handler set modkeyheld=1, and togglehidemode OFF leaves it at 1.
  - Wait: if hidemode was 1 and we're toggling to OFF, the chord handler doesn't fire first (because modkeyheld=1 from initial Super press). Let me retrace.
- Trace:
  1. key_press_bare_super: state=0x00, keysym=Super_L
     - Reconciliation: state has no Mod4Mask, modkeyheld=0 → no
     - Chord: state has no Mod4Mask → no
     - Bare Super: state has no Mod4Mask, !modkeyheld → modkeyheld=1, showbar=1 (hidemode=1)
  2. key_press_chord(XK_h): state=0x40(Mod4Mask), keysym=XK_h
     - Reconciliation: state has Mod4Mask → no
     - Chord: state has Mod4Mask, hidemode=1, !modkeyheld → modkeyheld is 1 → NO (doesn't fire)
     - Keybinding: Mod+H → togglehidemode()
     - togglehidemode OFF: hidemode=0, showbar=1. modkeyheld stays 1 (NOT reset in OFF path).
  3. key_release_super_after_chord: state=0x40(Mod4Mask), keysym=Super_L
     - keysym == Super_L → yes
     - modkeyheld=1 → yes → modkeyheld=0, hidemode=0 → autoshowuntil=0 (no timer)
  - Result: hidemode=0, modkeyheld=0, showbar=1 ✓

### 3. LOST Mod release: chord key release with state=Mod4Mask doesn't match bare Super grab (modifier=0)

**This is the suspected root cause of "mod key hold eventually breaking."**

**Setup**: hidemode=1, modkeyheld=0, autoshowuntil=0, showbar=0
**Events**: key_press_bare_super → 5 seconds pass → user has NOT released Super (modkeyheld still 1, lost release event)
**Then**: key_press_regular('a') — user presses 'a' in terminal
**Expected**:
- Reconciliation fires: modkeyheld=0, autoshowuntil=now+3 (hidemode=1)
- This correctly recovers from the lost release

**The real problem**: What sequence causes the Lost Mod release?

In X11, when you grab `Super_L + modifier=0`:
1. Press Super_L: state=0 → matches grab → KeyPress delivered ✓
2. Press 'h' while holding Super: state=Mod4Mask → Mod+H grab matches → KeyPress for 'h' ✓
3. Release 'h': state=Mod4Mask → Mod+H grab matches → KeyRelease for 'h' ✓
4. Release Super_L: state=??? 

For step 4: After step 3 (releasing 'h'), the keyboard state is: Super still physically held. The KeyRelease for Super_L arrives with state reflecting modifiers active before the release. Since 'h' was just released but Super is still held, the state should be Mod4Mask. 

The bare Super grab was for modifier=0. state=Mod4Mask does NOT match modifier=0. So the KeyRelease event goes to... the root window? dwm loses it.

**This means**: After ANY chord (Mod+H, Mod+Return, Mod+Left, etc.), the Super KeyRelease is LOST. `modkeyheld` stays at 1 forever (or until reconciliation).

But wait — the log shows "Mod RELEASE" being received after chords sometimes. Let's check: does X11 handle the grab matching differently for releases?

Actually, in X11, KeyRelease events follow the same grab matching as KeyPress. If the grab is for modifier=0 and the release state has Mod4Mask, the grab doesn't match. However, there's a catch: X11 delivers KeyRelease events to the same client that received the corresponding KeyPress, IF owner_events=True. Let me verify...

`XGrabKey(dpy, k, modifiers[j], root, True, GrabModeAsync, GrabModeAsync)` — the 4th argument `True` is `owner_events`. With owner_events=True, the grabbing client receives all events related to the grabbed key, including releases, regardless of modifier state changes during the hold.

Actually no, owner_events controls whether events are reported normally (True) or only to the grabbing client (False). For passive grabs (XGrabKey), the behavior is:
- KeyPress: delivered to the grabbing client if the grab matches
- KeyRelease: MUST be delivered to the SAME client that received the KeyPress

So if dwm received the KeyPress for Super_L (through the bare Super grab with modifier=0), it MUST also receive the KeyRelease for Super_L, even if the modifier state changed. This is per the X11 protocol.

So my theory about lost releases might be wrong for the normal case. The X server ensures KeyRelease delivery to the grabbing client.

BUT — there's a subtlety with CAPS LOCK remap. The Caps Lock key is remapped to Super_L. The XGrabKey for bare Super grabs the keycode that produces Super_L. But after the remap, Caps Lock's keycode also produces Super_L. The setup code iterates all keycodes and grabs those producing Super_L:

```c
for (k = start; k <= end; k++) {
    KeySym ks = syms[(k - start) * syms_per_code];
    if (ks == XK_Super_L) {
        for (j = 0; j < LENGTH(modifiers); j++)
            XGrabKey(dpy, k, modifiers[j], root, True, GrabModeAsync, GrabModeAsync);
    }
}
```

This should grab both the physical Super key and the Caps Lock key. So both should work.

OK, so let me not get bogged down in X11 grab theory. The test should model the CURRENT code behavior exactly, including the reconciliation paths, and then we can identify bugs by comparing expected vs. actual.

Let me write the test now.

### 4. Mod chord handler fires for keys OTHER than Super when modkeyheld=0

**Setup**: hidemode=1, modkeyheld=0 (e.g., after reconciliation), autoshowuntil=0, showbar=0
**Events**: key_press_chord(XK_Left) — user presses Mod+Left while modkeyheld is 0
**Expected**:
- Chord handler: state has Mod4Mask, hidemode=1, !modkeyheld → YES → modkeyheld=1, showbar=1
- This reveals the bar even though the initial Super KeyPress didn't set modkeyheld

**When does this happen?** When the Mod release was LOST, reconciliation resets modkeyheld. Then the user presses another chord key while still physically holding Mod. The chord handler fires and shows the bar. But the initial "Mod PRESS" is NOT logged (because it was already processed earlier and the release was lost).

**Actually**: After reconciliation, if the user has been holding Mod this whole time, the next chord keypress would have state=Mod4Mask (Mod still held) and modkeyheld=0. The chord handler fires. If the user then releases Mod, the KeyRelease arrives (modkeyheld=1 from chord handler), and dwm starts the auto-hide timer. This works.

But what if the user is NOT still holding Mod? What if they released Mod (lost event), then pressed a regular key? Reconciliation fires, modkeyheld=0. Then the user presses Mod again. This is a fresh KeyPress for Super_L with state=0. It should go through the normal bare Super path and log "Mod PRESS".

### 5. togglehidemode ON resets modkeyheld, OFF does not

This asymmetry is intentional but can cause confusion:
- ON: modkeyheld=0, bars hidden, autoshowuntil=0
- OFF: modkeyheld NOT reset, bars shown permanently

**Test**: hidemode=0 (OFF), press Mod+H to toggle ON
**Expected**: After toggle, modkeyheld should be 0 (reset by ON path). 
But if togglehidemode ON is triggered via a chord (Mod+H), the chord handler set modkeyheld=1 first, then togglehidemode ON resets it to 0. So when Super is released, modkeyheld=0 → "Mod RELEASE ignored". The bar stays hidden (correct for hide mode ON).

**Next Mod press** (after releasing and pressing again): Should work normally.

### 6. Rapid ON→OFF→ON toggling

Each toggle requires Mod+H, which means Mod press, H press, H release, Mod release for EACH toggle. If the Mod release is being lost (scenario 3), then after 2-3 toggles the state could become inconsistent.

### 7. Timer expiry edge cases

- Timer expires while modkeyheld=1: `if (autoshowuntil > 0 && now >= autoshowuntil)` triggers, but the inner check `if (hidemode && !modkeyheld)` prevents hiding because modkeyheld=1. The bar stays visible. Good.
- Timer fires with autoshowuntil=0: Nothing happens.
- Timer fires with hide mode OFF: updatebarvisibility returns immediately.

---

## Known Bugs (from log analysis)

### Bug A: Mod release event possibly lost after chord

After any Mod+key chord, the Super KeyRelease may not match the bare Super grab if the grab uses modifier=0. The reconciliation code in keypress handler recovers from this, but there's a window where modkeyheld=1 incorrectly.

**Impact**: If user does Mod+H to toggle, then releases Mod (lost), then presses 'a' in terminal → reconciliation fires → bar auto-shows for 3 seconds even though user didn't intend to reveal it.

### Bug B: No "Mod PRESS" log between toggles

In the session log, after the first few events, "Mod PRESS" stops appearing even though toggles continue via Mod+H. This suggests something is preventing the bare Super KeyPress from reaching the handler.

**Hypothesis**: After `grabkeys()` is called (e.g., in `mappingnotify`), the bare Super grabs are lost because `XUngrabKey(dpy, AnyKey, AnyModifier, root)` ungrabs them and `grabkeys()` only regrabs the keybinding entries, not the bare Super keys.

**Test for this**: Check if `grabkeys()` is called mid-session. Look for `MappingNotify` events.

### Bug C: togglehidemode OFF doesn't reset modkeyheld

If hidemode is ON and user does Mod+H to toggle OFF:
1. KeyPress Super_L: modkeyheld=1, showbar=1
2. KeyPress H: togglehidemode fires (OFF path), modkeyheld stays 1
3. Release H
4. Release Super_L: modkeyheld=1 → timer starts in hidemode=0 → updatebarvisibility returns immediately (good)

But what if step 4's release is lost? modkeyheld stays 1. Next regular keypress reconciles. This is OK.

**Impact**: Low. The asymmetry is weird but doesn't cause visible bugs in practice.

---

## Test Harness Design

The test is in `dwm-hide-mode-test.c`. It:
1. Implements all state variables and transition functions as extracted from dwm.c
2. Provides event simulation functions for all input types
3. Runs ~30 test scenarios
4. Each scenario: setup → apply events → assert expected state
5. Prints PASS/FAIL with detailed diagnostics
