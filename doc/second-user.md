# Second desktop user (`rs`) — what they get, what stays root-only

The machine was installed root-only. This document describes the extra user and
the boundaries, so "it works for rs" and "rs cannot do that" are both checkable.

## Create / repair the account (idempotent)

```bash
REPO_DIR=/root/Development/slackware-installer-for-rs \
  TARGET_USER=rs TARGET_PASS=rs ADD_WHEEL=false \
  bash /root/Development/slackware-installer-for-rs/steps/user-ensure.sh

REPO_DIR=/root/Development/slackware-installer-for-rs \
  TARGET_USER=rs bash /root/Development/slackware-installer-for-rs/steps/user-helpers.sh

# per-user dotfiles: .bashrc/.vimrc/.ssh, fastfetch, pi config, web shortcuts
cd /root/Development/slackware-installer-for-rs
TARGET_PASS=rs bash post-install-user.sh --user rs
```

`TARGET_PASS` makes `user-ensure.sh` set the password non-interactively
(`chpasswd`); without it a new account gets the normal `passwd` prompt and an
existing password is never rewritten. `ADD_WHEEL=false` on purpose — see below.

## What rs can use

Everything installed, as a normal desktop user:

| area | how |
|---|---|
| dwm / st / slock / xidle / dwm-status | `x`, Mod+Escape, per-user session log under `/var/log/rs/` |
| Chrome / Chromium | `/usr/local/bin/chrome`, `chromium` |
| audio, mic, VOX | rs's **own** PipeWire session at `/run/user/4877`, started by `pipewire-ensure` from `dwm-start` |
| video / camera / input / backlight | groups `video`, `input`, `audio`, `power` (plus `plugdev`, `netdev`, `cdrom`, `lp`, `scanner`, `kvm`, `dialout`, `tty`, `seat`) |
| Wi-Fi | `wifi` → `wifi-manager` (nmcli; rs may read and connect) |
| VPN, power/brightness, Soulseek | via the narrow passwordless helper rules (below) |
| pi coding agent | `/usr/local/bin/pi` → `/opt/pi-agent` (readable by all); config and API key in `~/.pi/agent`, mode 600 |
| URL shortcuts | `~/.web/shortcuts`, from `dotfiles/chromium/shortcuts.default` |
| desktop background | `~/.dwm-background`, else `/etc/dwm/backgrounds.conf` (`rs=#808080`) |

## Narrow sudo (granted to `rs`, not to `wheel`)

`/etc/sudoers.d/50-user-rs-helpers` — installed by `steps/user-helpers.sh`:

```
rs ALL=(ALL) NOPASSWD: /usr/local/bin/power
rs ALL=(ALL) NOPASSWD: /usr/local/bin/vpn, /usr/sbin/openvpn, /usr/bin/setsid,
    /usr/bin/chmod, /usr/bin/pkill, /sbin/sysctl, /usr/sbin/iptables,
    /usr/sbin/ip6tables, /sbin/ip, /usr/sbin/ip
rs ALL=(ALL) NOPASSWD: /etc/rc.d/rc.slskd *
```

These are exactly the commands the installed tools call through `sudo -n`
(`scripts/power.sh`, `scripts/vpn.sh`, `scripts/slsk.sh`). Without them those
features fail for a non-root user; with them `rs` still has no shell, no
package management and no arbitrary root command.

## Deliberately NOT available to rs

* `/etc/sudoers` `%wheel` (commented out) and `ADD_WHEEL` — no `sudo -i`,
  `sudo -s`, `su`, or arbitrary `sudo <cmd>`.
* Package management: `installpkg`, `upgradepkg`, `removepkg`, `slackpkg
  install/upgrade` cannot write `/var/log/packages` or `/var/lib/pkgtools`.
* The installer repo and keys: `/root` is `drwx--x--- root:root`, so
  `/root/Development/slackware-installer-for-rs` (and `setup.keys.*`) is
  unreadable and unwritable.
* `disk`, `mem`, `kmem`, `raw`, `root` groups (root-equivalent hardware access).

## Per-user desktop background

`dwm-start` resolves the colour in this order:

1. `~/.dwm-background` (one colour) — written by `dwm-background '#808080'`
2. `/etc/dwm/backgrounds.conf` — `user=#RRGGBB`, then `default=`
3. built-in fallback `#808080`

```
root  -> #CC0000   (signal red, unchanged)
rs    -> #808080   (medium grey)
others-> #808080   (default)
```

Source: `dotfiles/dwm/backgrounds.conf`, installed by `steps/suckless-dwm.sh`.
Each user can change their own with `bg '#5a5a5a'` (alias for
`/usr/local/bin/dwm-background.sh`), which applies immediately when `DISPLAY`
is set and persists in `~/.dwm-background`.

## Locking / sleeping as rs

`slock` is installed **setuid root** (`4755`): `pam_unix` must read
`/etc/shadow`, which a normal user cannot. The lock marker is per user —
`/run/slock.locked` for root, `$XDG_RUNTIME_DIR/slock.locked` for everyone else
(`/run` is not writable by rs). `scripts/lock-screen.sh` and `scripts/idle-lock.sh`
compute the same path.

The elogind sleep hook (`10-slock-lock`, runs as root) finds the active seat's
session via `loginctl` and re-runs `lock-screen.sh` **as that user**, so a lid
close in rs's session still guarantees "nothing visible on wake except slock".
Root's single-user path is unchanged (`xuser=root`).

## Known caveat: power-button countdown text

`powerkey-hold` runs once at boot as root, so its 0.1 s countdown and the
`Shutting Down Now...` topbar line are written to `/run/user/0/status_msg`.
The shutdown itself works from any session (and the message still reaches every
terminal via `broadcast` and `/dev/console`); only the topbar copy is root's.
That daemon was left untouched on purpose — it is the power path.
