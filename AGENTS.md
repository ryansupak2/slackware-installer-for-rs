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
