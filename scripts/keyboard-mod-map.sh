#!/bin/sh
# keyboard-mod-map — apply the Mod key map for this X session
#
# Called from the xinitrc that scripts/dwm-start.sh generates, at EVERY X start.
# It lives in its own installed file on purpose: the xinitrc is generated once
# per dwm-start and cached in /tmp, so a mapping edited into that heredoc does
# not exist for a session that was started from an older copy of the script —
# which is exactly how the Copilot/Caps mapping silently vanished after an X
# restart (2026-11-13). This file is read fresh on every start.
#
#   Caps Lock (keycode 66) : Super_L only — Mod and NOTHING ELSE. No second
#                            level, so no chord can produce Caps_Lock: measured
#                            2026-11-13, both Shift+CapsLock and
#                            Copilot+CapsLock toggled the lock while level 2
#                            was Caps_Lock, and neither is wanted.
#                            Fn never reaches software (the AT keyboard does not
#                            advertise KEY_FN, and an evdev capture of the user
#                            pressing it showed no event at all), so Fn+CapsLock
#                            cannot be bound either: turning caps lock on is
#                            deliberately unbound for now. See the AGENTS.md
#                            "Keyboard" section before adding a chord back —
#                            it must not be Mod+something.
#   Copilot (keycode 201, evdev KEY_F23) : Super_L (Mod). Its firmware also
#                            presses Shift; /usr/local/bin/copilot-mod drops that
#                            Shift from the server's state, because dwm matches
#                            grab masks exactly (Mod+X would become Mod+Shift+X,
#                            and Mod+Return would never reach dwm at all).
#
# Idempotent: xmodmap -e is a set, not an append; running it twice changes
# nothing. Safe to run by hand at any time.

# A missing DISPLAY means "not in X": nothing to do, not an error.
[ -n "${DISPLAY:-}" ] || exit 0

xmodmap -e "clear lock" 2>/dev/null || true
xmodmap -e "keycode 66 = Super_L" 2>/dev/null || true
# Both levels Super_L, not just level 1: the xkb type inherited from the stock
# map is PC_SHIFT_SUPER_LEVEL2, whose level 2 is NoSymbol. If the firmware's
# Shift ever survives (daemon not running), Shift selects level 2 and the key
# would assert nothing; with Super_L on both levels it is Mod either way.
xmodmap -e "keycode 201 = Super_L Super_L" 2>/dev/null || true
xmodmap -e "add mod4 = Super_L" 2>/dev/null || true

exit 0
