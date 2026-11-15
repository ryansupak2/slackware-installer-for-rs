# slskd — Soulseek, one instance per login session

slskd runs **as the logged-in user, inside that user's session, and only while
that session exists**. It is not a boot service.

| path | what |
|---|---|
| `/opt/slskd/slskd` | the binary (standalone linux-x64 zip from the slskd release) |
| `/etc/slskd/slskd.yml` | **template** — copied per user on first start, never read by a running slskd |
| `~/.local/share/slskd/slskd.yml` | the user's own config (editable, web-UI writable) |
| `~/.local/share/slskd/data/` | the user's database (search history, transfers) |
| `/var/lib/slskd/music` | shared library, `0755 root:slskd`, read by every user |
| `/var/lib/slskd/downloads` | shared downloads, `2775 root:slskd` **setgid** so both users keep access |
| `/var/log/<user>-slskd.log` | control-script lines + slskd's own log, append-only |
| `/usr/local/bin/slsk` | the control command (no sudo, ever) |

## Commands

```bash
slsk start          # start it as YOU in this login session (dwm-start does this too)
slsk stop           # stop YOUR instance (graceful TERM, 15 s, then KILL)
slsk restart
slsk status         # pid, web UI, app dir, log
slsk log            # tail -f the log
slsk reset-config   # drop ~/.local/share/slskd/slskd.yml so the template is copied again
```

There is no `slskd` service, no `/etc/rc.d/rc.slskd`, no `/etc/sudoers.d/slskd`
and no rc.local line: all four were removed on 2026-11-15. (`steps/slskd.sh`
removes them idempotently if they come back.)

## Why it is per session

It used to be the opposite: `useradd -r slskd`, started by `/etc/rc.d/rc.local`
at boot, controlled through `sudo /etc/rc.d/rc.slskd`. Consequences, measured:

* it was running at the login prompt and **survived every logout and user
  change**;
* only root (or `%wheel`, which `rs` is not in) could start or stop it — `slsk`
  as `rs` failed with "need root or sudo/doas";
* its `HOME`/data were `/var/lib/slskd`, so it owned the shared library — a
  second user could not write downloads at all.

Now the lifetime is the session's: `scripts/dwm-start.sh` runs
`slsk start --session-start` before `startx`, dwm-start's EXIT trap runs
`slsk stop`, `scripts/session-stop` names `slskd` among the per-user daemons,
and elogind's `KillUserProcesses=yes` (steps/session-cleanup.sh) is the
backstop when X dies hard. The daemon inherits the session's elogind cgroup, so
the kill works by cgroup, not by pid hunting.

Data persists, the process does not: the database and the library survive a
logout; the daemon does not.

## Verify

```bash
slsk status                                  # running, pid, user
pgrep -a -x slskd                            # the process
sed -n 's/.*name=elogind:\/\([0-9]*\).*/\1/p' /proc/$(pgrep -x slskd|head -1)/cgroup
                                             # -> that session's id (kill scope)
ss -ltnp 'sport = :5030'                     # web UI listener
grep -E 'Logged in to the Soulseek server' /var/log/root-slskd.log | tail -2

# privileges left on the Soulseek account (seconds -> days:
# privilegesRemaining 40361309 = 467 days 03 h 28 min on 2026-11-14):
curl -s http://localhost:5030/api/v0/application \
  | python3 -c 'import json,sys; u=json.load(sys.stdin)["user"]; print(u["username"], u["privileges"])'
```

`rs` works the same way — no sudo:

```bash
runuser -u rs -- /usr/local/bin/slsk status
```

## Traps that already cost time

* **slskd uses its current directory as the ASP.NET content root.** Started from
  a directory the user cannot read (measured: `runuser -u rs` inherits root's
  cwd) it dies at startup with
  `System.IO.DirectoryNotFoundException: /root/Development/slackware-installer-for-rs/`.
  `slsk start` therefore `cd`s into the app dir before `setsid`.
* **`steps/slskd.sh` writes the config template with an unquoted heredoc** (it
  must expand `SLSKD_USERNAME`/`SLSKD_PASSWORD`/ports). A backtick in that body
  is executed while the step runs — an old `` `slsk start` `` inside a comment
  started the daemon and printed its output into `/etc/slskd/slskd.yml`. Keep
  command words in plain quotes.
* **The ports are shared** (5030 web, 50300 Soulseek) while the data is per
  user. Two users cannot both run it; `slsk start` refuses with the name of the
  process holding the port instead of failing silently.
* **Group membership applies at the next login.** `steps/slskd.sh` adds every
  human user (uid ≥ 1000) to group `slskd`; a session that is already running
  keeps its old group list, so downloads into `/var/lib/slskd/downloads` appear
  to fail for that user until they log in again.
* **Config edits to `/etc/slskd/slskd.yml` do not reach an existing user.**
  Their copy in `~/.local/share/slskd/slskd.yml` wins; `slsk reset-config`
  drops it (the next start re-copies the template).
