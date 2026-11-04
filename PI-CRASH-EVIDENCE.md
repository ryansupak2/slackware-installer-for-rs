# PI-CRASH-EVIDENCE.md — pi crash investigation

## Evidence Summary

### 1. The crash mechanism: st exits → EIO on TTY read

**st (the terminal emulator) dies first, not pi.** st is vanilla 0.9.2 with no
X11 error handler set. When the X11 connection breaks under heavy rendering
load, Xlib's default I/O error handler calls `exit(1)` — no signal, no core dump,
the window silently disappears.

When st exits, the pty master closes. The kernel sends SIGHUP to pi (the
controlling process). pi reads from the dead TTY, gets:

```
Error: read EIO
    at TTY.onStreamRead (node:internal/stream_base_commons:216:20)
    errno: -5, code: 'EIO', syscall: 'read'
```

### 2. The trigger: rapid parallel tool calls overwhelm st's rendering

From the crash evidence bundle (MANIFEST.txt):

> The crash happens when the pi agent makes rapid parallel tool calls (bash
> commands like curl/find/ls) which overload the pi.dev backend.

The user reported: *"curl requests beyond just one or two at once are crashing
pi.dev."*

**What's really happening:** st 0.9.2 is single-threaded with synchronous X11
rendering. Each pi TUI frame is ~136×37 characters plus extensive ANSI escape
sequences. Berkeley Mono at 24px requires Xft glyph lookups per character.
Rapid parallel tool calls produce simultaneous output bursts that st cannot
render in time. The X11 output buffer fills up, the connection stalls, and the
default X11 I/O error handler calls `exit(1)`.

**st source confirms this:** `x.c` has zero calls to `XSetIOErrorHandler()` —
no custom handler is set. When Xlib detects a broken connection, the default
handler prints a message to stderr (lost when st is launched from dwm) and exits.

**Why only in X:** On the Linux console (`TERM=linux`), there is no X11 connection
to break. This is why crashes only happen inside the graphical session.

### 3. Exit code 129 = SIGHUP

From `rs-pi-stack-20260728-150101.txt`:

```
label: exit-129
time: 2026-07-28T20:01:01.519Z
pid: 9557
```

Exit code 129 = 128 + 1 = SIGHUP (hangup). The terminal was disconnected.
pi received SIGHUP because its controlling terminal vanished.

### 4. Crash handler never fires

- **All `rs-pi-stderr-*.log` files are 0 bytes** — stderr is never flushed.
- **No `rs-pi-nodecrashdump-*.json` files exist** — `process.report.writeReport()`
  never produced output.
- `NODE_OPTIONS` included `--trace-uncaught --report-on-fatalerror
  --report-uncaught-exception` — flags were correct, handler never ran.

From MANIFEST:

> 1. Why does crash handler's process.exit(1) not flush stderr?
> 2. Is the undici HTTP dispatcher (configureHttpDispatcher) closing the TTY fd?
> 3. Is there a race between TTY shutdown and the agent event loop?

### 5. Key files examined

| File | What it showed |
|------|---------------|
| `/home/rs/logs/rs-pi-stack-20260728-150101.txt` | exit-129 (SIGHUP) |
| `/home/rs/pi-crash-evidence/pi-crash-bundle-20260728-144150/MANIFEST.txt` | Full crash diagnosis by user |
| `/home/rs/pi-crash-evidence/pi-crash-bundle-20260728-144150/environment.txt` | pi v0.82.1, NODE_OPTIONS with crash reporting |
| `/home/rs/pi-crash-evidence/pi-crash-bundle-20260728-144150/pi-debug.log` | Agent making parallel grep/find/read calls |
| `/home/rs/logs/rs-pi-tui-20260729-095857.log` | User saying "you are crashing pi - is it the curls? do not do curls or greps concurrently" |
| `/var/log/root-pi-nodecrashdump-20260728-*.json` | Simulated crashes (TEST/synthetic) — NOT real, but confirm crash reporting works in controlled conditions |

---

## What to do about it

### Immediate (project-level — can do now)

1. **Add a hard rule to AGENTS.md:**
   - Never make parallel/concurrent tool calls.
   - One curl at a time. Wait for it to finish before starting another.
   - Never pipe curl output directly into python3; use temp files.
   - No parallel grep + find + ls batches. Serialize all bash calls.

2. **Run pi inside `tmux` or `screen`:**
   - tmux creates its own pty that survives the outer terminal dying.
   - If st crashes, tmux keeps running. Reattach with `tmux attach`.
   - Currently: `TMUX=<none>`, `STY=<none>` — completely unprotected.

3. **Replace st with a GPU-accelerated / async terminal:**
   - Options: **alacritty** (Rust, GPU-rendered), **foot** (Wayland, async), **kitty** (GPU).
   - These render asynchronously and won't stall on rapid output.
   - st is single-threaded and does all rendering synchronously via Xlib/Xft.

### st-level (terminal fix)

| Problem | Suggested fix |
|---------|---------------|
| st has no X11 I/O error handler | Add `XSetIOErrorHandler()` in `x.c` that logs the error before exiting |
| st does synchronous X11 rendering | Patch st to use double-buffering or async rendering, or switch to alacritty/foot/kitty |
| st launched from dwm, stderr lost | Redirect st's stderr to a log file in `dwm-start.sh` to capture X11 error messages |

### pi-level

| Problem | Suggested fix |
|---------|---------------|
| EIO on TTY read kills the process | Catch EIO gracefully — treat it like EOF, flush logs, exit cleanly |
| Crash handler never writes stderr | Use `fs.writeSync(2, ...)` instead of `console.error` to bypass stream buffering |
| SIGHUP kills before cleanup | Install a SIGHUP handler that flushes logs then exits |

### System-level

- **ulimit -n is 4096** — should be sufficient, but worth monitoring `lsof` during
  an agent session to see how many FDs are in use.
- **Test with `strace`** on a pi session to catch exactly when the EIO fires
  and what syscalls precede it.
