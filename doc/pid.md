# `pid` — pi with debug/crash logging

`pid` is a bash function defined in `/etc/skel/.bashrc` that wraps the `pi`
coding agent with debug logging enabled.  On crash, it captures three artifacts
that share a single timestamp so they group together in `ls -lt`.

## Invocation

```bash
pid [args...]
```

## What it does

1. Creates a single timestamp (`ts`) via `date +%Y%m%d-%H%M%S`.
2. Sets up three log paths under `/var/log`:
   - **TUI log**:   `${USER}-pi-tui-$ts.log`     — full terminal output via `PI_TUI_WRITE_LOG`
   - **stderr log**: `${USER}-pi-stderr-$ts.log`  — stderr captured with `2>`
   - **node crash dump**: `${USER}-pi-nodecrashdump-$ts.json` — Node.js diagnostic report
3. Exports `PI_DEBUG=1` and `NODE_OPTIONS` with:
   ```
   --trace-uncaught
   --report-on-fatalerror
   --report-uncaught-exception
   --report-filename=<nodecrashdump>
   ```
4. Runs `pi --readonly` (with optional `@SYSTEM.MD`) under those settings.
5. On non-zero exit, prints the paths of all three files to stderr.

## Crash artifacts (the three files)

| File | Purpose | Set by |
|------|---------|--------|
| `*-pi-tui-$ts.log` | Full TUI session capture | `PI_TUI_WRITE_LOG` env var |
| `*-pi-stderr-$ts.log` | stderr of the pi process | shell `2>` redirect |
| `*-pi-nodecrashdump-$ts.json` | Node.js diagnostic report | `--report-filename` in `NODE_OPTIONS` |

All three share the same `$ts` so they sort together naturally.

## How pi writes the node crash dump

When pi hits an uncaught exception, its handler in `interactive-mode.js` calls:

```js
try { process.report.writeReport(); } catch {}
process.exit(1);
```

Node.js writes the report to the filename specified by `--report-filename`,
which `pid` set to the timestamped `nodecrashdump` path.

## Example output on crash

```
pid: DEBUG MODE
  TUI:    /var/log/root-pi-tui-20260728-091033.log
  stderr: /var/log/root-pi-stderr-20260728-091033.log
  nodecrashdump: /var/log/root-pi-nodecrashdump-20260728-091033.json
...
pid: pi crashed (exit=1)
  stderr log: /var/log/root-pi-stderr-20260728-091033.log
  TUI log:    /var/log/root-pi-tui-20260728-091033.log
  node reports in: /var/log/
```
