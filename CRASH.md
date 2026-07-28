# CRASH.md — pi crash reporting and diagnosis

## How crash dumps work

Every pi session (both normal `pi` and debug `pid`) now writes a Node.js crash
report on any uncaught exception. Reports land in `/var/log/` with this pattern:

```
/var/log/<user>-pi-nodecrashdump-YYYYMMDD-HHMMSS.json
```

### The two launchers

Both are bash functions defined in `~/.bashrc` (canonical source: `dotfiles/shell/bashrc`).

**`pi()` — normal mode** (crash dump only, no overhead):
```bash
pi() {
    local log_dir="/var/log"
    [ -w "$log_dir" ] || log_dir="$HOME/logs"
    mkdir -p "$log_dir" 2>/dev/null || true
    local ts="$(date +%Y%m%d-%H%M%S)"
    local nodecrashdump="$log_dir/${USER:-root}-pi-nodecrashdump-$ts.json"
    export NODE_OPTIONS="--report-on-fatalerror --report-uncaught-exception --report-filename=$nodecrashdump"
    # ... launches "command pi --readonly" with optional @SYSTEM.MD
}
```

**`pid()` — debug mode** (full TUI capture + crash dump + stderr log):
```bash
pid() {
    # Creates three timestamped log files:
    #   1. /var/log/root-pi-tui-YYYYMMDD-HHMMSS.log      (terminal output)
    #   2. /var/log/root-pi-stderr-YYYYMMDD-HHMMSS.log    (stderr)
    #   3. /var/log/root-pi-nodecrashdump-YYYYMMDD-HHMMSS.json  (node report)
    export PI_DEBUG=1
    export NODE_OPTIONS="--trace-uncaught --report-on-fatalerror --report-uncaught-exception --report-filename=$nodecrashdump"
    PI_TUI_WRITE_LOG="$tui_log" command pi --readonly ... 2>"$err_log"
}
```

Key difference: `pid` adds `--trace-uncaught` and `PI_TUI_WRITE_LOG` for full
TUI capture. Both set `--report-filename` so crashes produce a JSON dump.

## Where to find crash evidence

| Artifact | Path | Contents |
|----------|------|----------|
| **Node crash dump** | `/var/log/<user>-pi-nodecrashdump-*.json` | Full Node.js diagnostic report (stack, heap, libuv, env, limits, shared objects) |
| **TUI log** (pid only) | `/var/log/<user>-pi-tui-*.log` | All terminal output from the pi session |
| **stderr log** (pid only) | `/var/log/<user>-pi-stderr-*.log` | stderr capture (often empty unless crash occurred) |
| **zipped crash bundle** | `/root/pi-crash-YYYYMMDD-HHMM.zip` | Archive of crash dumps for sharing/diagnosis |

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

## Log conventions (project-wide)

All project components log to `/var/log/` following the pattern:
```
/var/log/<user>-<component>-YYYYMMDD-HHMMSS.log
```

See `AGENTS.md` for full logging conventions across session scripts, daemons,
toggle scripts, and C code.

## Quick diagnosis checklist

1. **Did pi crash?** — Check for new `nodecrashdump` files: `ls -lt /var/log/*nodecrashdump*`
2. **What crashed?** — Inspect `javascriptStack.message` and `javascriptStack.stack` in the JSON
3. **What was the environment?** — Look at `environmentVariables` in the JSON
4. **Need full TUI replay?** — Use `pid` mode and check the `-pi-tui-*.log`
5. **Sharing with others?** — Zip the crash dump: `zip pi-crash-$(date +%Y%m%d-%H%M).zip /var/log/root-pi-nodecrashdump-*.json`
