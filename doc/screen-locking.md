# Screen locking — "on wake you can only ever see slock"

## Behaviour

| action | what happens |
|---|---|
| **close the lid** | the machine **suspends** — the normal laptop behaviour (elogind `HandleLidSwitch=suspend`). No more `poweroff` on lid close. |
| **open the lid** | wakes the machine and shows **slock**, already covering the screen. |
| **idle for `BLANK_MINUTES` (5 by default)** | screen is locked **20 s before** the panel blanks, then the panel blanks on top of it. Waking the display shows slock. |
| **Mod+Escape** | locks immediately (dwm binding, `dotfiles/suckless/dwm/config.h`). |
| **`/usr/local/bin/lock-screen.sh`** | same thing from a shell; returns 0 only once the screen is covered. |
| unlock | type `$USER`'s password (root here). Colours: olive = idle, green = typing, yellow = checking, red = wrong. |

No screen content is ever shown before slock covers it, by construction — see
below.

## The guarantee, mechanically

`slock` writes **`/run/slock.locked`** (its pid) only *after* both the keyboard
and pointer grabs have succeeded and the olive frame is on screen
(`sources/slock/slock.c`, `mark_locked()` after `grab_inputs()`), and removes it
on unlock. Every path that could expose the desktop waits for that marker:

```
sources/slock/slock.c ──> /run/slock.locked
        ▲                        │
        │                        ▼
scripts/lock-screen.sh ── blocks until the marker exists and its pid is really
        ▲                  slock (≤5 s), exits 0 only then
        │
        ├── /lib64/elogind/system-sleep/10-slock-lock   (pre: before suspend,
        │                                                post: after resume)
        ├── scripts/idle-lock.sh   (at BLANK_MINUTES*60 - 20 s idle)
        └── dwm Mod+Escape
```

So "lock before suspend" is not a `sleep 1 && hope`: the sleep hook does not
return until slock reports its grabs are held, and elogind does not continue
into suspend until that hook exits.

Two secondary details that matter for the same goal:

* Unlock ordering (`unlock_and_exit`): the covering window is destroyed **while
  the grabs are still held**, so no keystroke can reach the window underneath
  during the instant the desktop becomes visible. The grabs are released
  implicitly by closing the display connection.
* A stale marker cannot fake a lock: `lock-screen.sh` and `idle-lock.sh` both
  validate the pid in it against `/proc/<pid>/comm` == `slock`.

## Pieces

| file | role |
|---|---|
| `sources/slock/slock.c` | the locker (fullscreen override-redirect window, PAM auth, colour feedback) |
| `sources/xidle/xidle.c` | idle milliseconds via MIT-SCREEN-SAVER (nothing in the base system reports idle time) |
| `scripts/lock-screen.sh` | lock + wait until covered (exit 0 = covered) |
| `scripts/idle-lock.sh` | locks before the DPMS blank; started by `scripts/dwm-start.sh` |
| `steps/slock.sh` | builds/installs slock, xidle and both helpers, `/etc/pam.d/slock`, verifies the PAM stack |
| `steps/screen-locking.sh` | lid = suspend, sleep hook, removes the old ACPI `poweroff` handler |
| `steps/acpi-wakeup.sh` | wake sources = power button **+ lid** (so lid-open resumes); keyboard/touchpad/USB/RTC stay disabled |

## Verify

```bash
# locking works and is provable (scratch display, does not touch the session):
Xvfb :97 -screen 0 1600x1200x24 &
DISPLAY=:97 XAUTHORITY= /usr/local/bin/lock-screen.sh; echo rc=$?
cat /run/slock.locked            # pid of slock

# policy in place:
grep HandleLidSwitch /etc/elogind/logind.conf.d/*.conf      # suspend
ls -l /etc/acpi/events/                                    # no lid-close
ls -l /lib64/elogind/system-sleep/10-slock-lock            # sleep hook
cat /sys/devices/pci0000:00/0000:00:1f.0/PNP0C09:00/PNP0C0D:00/power/wakeup  # enabled

# the idle watcher:
pgrep -af idle-lock.sh
DISPLAY=:0 XAUTHORITY=/root/.Xauthority /usr/local/bin/xidle   # ms idle now

# real end-to-end test: close the lid, wait for the fan to stop, open it.
# You must see slock — never the desktop.
```

## Knobs

| knob | where |
|---|---|
| blank/idle timeout | `BLANK_MINUTES` in `/var/lib/power/state` (managed by `power`); lock fires 20 s earlier |
| lock lead time | `IDLE_LOCK_LEAD` (seconds) when running `idle-lock.sh` |
| docked lid | `HandleLidSwitchDocked=ignore` — closing the lid with an external display attached does not suspend |

## Three places must keep the lid wake source enabled

Lid close only helps if lid **open** can wake the machine. The lid switch
(`PNP0C0D`) is enabled in three separate paths, and all three had to be changed
from the old "power button only" policy — if you touch one, check the others:

| place | what it does |
|---|---|
| `/etc/rc.d/rc.local` (written by `steps/acpi-wakeup.sh`) | disables every wakeup source except power button + lid at boot |
| `scripts/power.sh` → `wake_restrict()` | same restriction, re-applied by `power boot` on every X start |
| `steps/wakeup-power-only.sh` → `/usr/local/bin/wakeup-power-only` | re-applied by the elogind `post` hook after resume |

The policy token in `/var/lib/power/state` is `WAKE=power-button-lid` (older
files said `power-button-only`; `load_state()` maps it forward). The lid's
wakeup attributes live on the EC node:
`/sys/devices/pci0000:00/0000:00:1f.0/PNP0C09:00/PNP0C0D:00/power/wakeup` —
the `LNXSYSTM/LNXSYBUS` alias that also carries `PNP0C0D` has no such file, so
grepping for the usual path finds nothing.

Sleep-hook order in `/lib64/elogind/system-sleep/`: `10-slock-lock` runs before
`power.sh`, so the screen is locked before the post-resume power policy runs.

## Recovery notes

* slock ignores `SIGINT`/`SIGTERM` on purpose. If it ever wedges: `Ctrl+Alt+F2`
  (X handles VT switches itself, grabs do not block them), log in, then
  `pkill -9 slock`, or `sudo kill -9` over SSH.
* The display-commit stall described in `doc/display-freeze.md` can freeze the
  *picture* while locked. The keyboard is already grabbed by slock, so the
  recovery is the same: VT switch, kill slock, restart X if needed.
* If a stale `/run/slock.locked` appears after a hard kill, it is harmless — both
  helpers check the pid before trusting it, and `idle-lock.sh` removes it.
