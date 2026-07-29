# CRASH.md — pi crash reporting and diagnosis

## How crash dumps work

Every pi session (both normal `pi` and debug `pid`) writes a Node.js crash
report on any uncaught exception. Reports land in the project log directory,
which follows the convention `/var/log`:

```
/var/log/<user>/pi_nodecrashdump-YYYYMMDD-HHMMSS.json
```

All project components use this same pattern — no separate `/var/log/sessions/`.
### The two launchers

Both are bash functions defined in `~/.bashrc` (canonical source: `dotfiles/shell/bashrc`).

**`pi()` — normal mode** (crash dump only, no overhead):
```bash
pi() {
    local log_dir="/var/log/${USER:-root}"
    mkdir -p "$log_dir" 2>/dev/null || true
    local ts="$(date +%Y%m%d-%H%M%S)"
    local nodecrashdump="$log_dir/pi_nodecrashdump-$ts.json"
    export NODE_OPTIONS="--report-on-fatalerror --report-uncaught-exception --report-filename=$nodecrashdump"
    # ... launches "command pi --readonly" with optional @SYSTEM.MD
}
```

**`pid()` — debug mode** (full TUI capture + crash dump + stderr log):
```bash
pid() {
    # Creates three timestamped log files:
    #   1. $log_dir/pi_tui-YYYYMMDD-HHMMSS.log         (terminal output)
    #   2. $log_dir/pi_stderr-YYYYMMDD-HHMMSS.log       (stderr)
    #   3. $log_dir/pi_nodecrashdump-YYYYMMDD-HHMMSS.json  (node report)
    export PI_DEBUG=1
    export NODE_OPTIONS="--trace-uncaught --report-on-fatalerror --report-uncaught-exception --report-filename=$nodecrashdump"
    PI_TUI_WRITE_LOG="$tui_log" command pi --readonly ... 2>"$err_log"
}
```

Key difference: `pid` adds `--trace-uncaught` and `PI_TUI_WRITE_LOG` for full
TUI capture. Both set `--report-filename` so crashes produce a JSON dump.

## Where to find ALL log files

When investigating a crash (pi, st, or anything else), look here first.
All components follow the same convention: `/var/log`.

| Component | Log path | Content |
|-----------|----------|---------|
| **pi node crash dump** | `<dir>/pi_nodecrashdump-YYYYMMDD-HHMMSS.json` | Full Node.js diagnostic (stack, heap, libuv, env) |
| **pi TUI** (pid mode) | `<dir>/pi_tui-YYYYMMDD-HHMMSS.log` | Full terminal output from pi session |
| **pi stderr** (pid mode) | `<dir>/pi_stderr-YYYYMMDD-HHMMSS.log` | stderr capture (often empty unless crash) |
| **st (terminal) errors** | `<dir>/st-YYYYMMDD-HHMMSS.log` | X11 I/O errors, font errors, etc. |
| **dwm session** | `<dir>/dwm-YYYYMMDD-HHMMSS.log` | Entire X session output (dwm + all children) |
| **dwm status bar** | `<dir>/dwmstatus-YYYYMMDD-HHMMSS.log` | Status bar generator output |
| **net-watch** | `<dir>/netwatch-YYYYMMDD-HHMMSS.log` | Internet connectivity watcher |
| **VPN** | `<dir>/vpn-YYYYMMDD-HHMMSS.log` | VPN connect/disconnect/output |
| **VPN suspend** | `<dir>/vpnsuspend-YYYYMMDD-HHMMSS.log` | VPN suspend/resume handler |
| **VNC** | `<dir>/vnc-YYYYMMDD-HHMMSS.log` | Screen sharing manager |
| **wifi-manager** | `<dir>/wifimanager-YYYYMMDD-HHMMSS.log` | WiFi connection tool |
| **shell init** | `<dir>/shellinit-YYYYMMDD-HHMMSS.log` | Shell startup errors |
| **audio boot** | `<dir>/audioboot-YYYYMMDD-HHMMSS.log` | Audio device initialization |
| **vox daemon** | `<dir>/vox-YYYYMMDD-HHMMSS.log` | Voice dictation daemon |
| **vox toggle** | `<dir>/voxtoggle-YYYYMMDD-HHMMSS.log` | Dictation toggle events |

`<dir>` = `/var/log/<user>`.  E.g. `/var/log/rs/dwm-20260729-120000.log`.

### st crash investigation

If pi crashes silently (no nodecrashdump, empty stderr), the terminal (st)
likely died first. Check:

```bash
# st error log (each st window gets its own timestamped log)
ls -lt /var/log/rs/st-*.log | head -3

# dwm session log (st runs inside this)
ls -lt /var/log/rs/dwm-*.log | head -1   # latest dwm session
```
```

## Crash dump JSON structure

A `nodecrashdump` JSON file contains these top-level keys:

- `header` — event type, trigger, filename, timestamp (ISO 8601 + epoch ms), PID, node version, OS info
- `javascriptStack` — JS callstack at crash time (message + stack frames)
- `javascriptHeap` — V8 heap state (spaces, usage, limits)
- `nativeStack` — C++/native frames (pc addresses + symbols)
- `resourceUsage` — RSS, CPU, page faults, FS activity
- `uvthreadResourceUsage` — libuv thread resource usage
- `libuv` — libuv handle state (async, timer, check, prepare, pipe, loop)
- `workers` — worker thread state
- `environmentVariables` — full env snapshot (useful for reproducing)
- `userLimits` — ulimit values
- `sharedObjects` — loaded .so libraries

## The crash handler in pi

Located in `dist/modes/interactive/interactive-mode.js` (compiled TypeScript):

```js
// Line ~2940
console.error("pi exiting due to uncaughtException:");
console.error(error);
try { process.report.writeReport(); } catch {}
process.exit(1);
```

Registered via:
```js
const uncaughtExceptionHandler = (error) => this.uncaughtCrash(error);
process.prependListener("uncaughtException", uncaughtExceptionHandler);
```

The handler:
1. Logs the error to stderr
2. Calls `process.report.writeReport()` — this writes to the path specified by `--report-filename`
3. Exits with code 1

## AGENT RULE: NEVER simulate crashes unprompted

**DO NOT** run `node -e` or any other command that deliberately throws an
uncaught exception to "test" crash reporting. Crash dumps are a diagnostic
artifact of REAL crashes only. Generating fake ones pollutes the log directory
and confuses debugging. If the user explicitly asks you to test crash reporting,
ask them to confirm before proceeding.

## Log conventions (project-wide)

All project components log to `/var/log/<user>/<component>-YYYYMMDD-HHMMSS.log`.

Component names have no dashes (e.g., `dwmstatus` not `dwm-status`,
`pi_tui` not `pi-tui`). See the table above for every component.

## Quick diagnosis checklist

1. **Did anything crash?** — Scan recent logs across all components:
   ```bash
   ls -lt /var/log/rs/* /var/log/root/* 2>/dev/null | head -20
   ```

2. **Did pi crash?** — Check for new nodecrashdump files:
   ```bash
   ls -lt /var/log/*/pi_nodecrashdump* 2>/dev/null
   ```
   If found, inspect `javascriptStack.message` in the JSON.

3. **Did st crash?** — No nodecrashdump + empty pi stderr + st window vanished:
   ```bash
   tail -50 /var/log/rs/st-*.log | tail -50          # X11 I/O error messages
   tail -50 /var/log/rs/dwm-*.log | tail -50  # dwm session log (st output)
   ```

4. **Need full TUI replay?** — `pid` mode writes `-pi_tui-*.log`.

5. **Sharing with others?** — Zip the evidence:
   ```bash
   zip pi-crash-$(date +%Y%m%d-%H%M).zip \
     $log_dir/pi_nodecrashdump-*.json \
     $log_dir/pi_tui-*.log \
     $log_dir/pi_stderr-*.log \
     $log_dir/st-*.log \
     $log_dir/dwm-*.log
   ```
