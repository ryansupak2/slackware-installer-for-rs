#!/usr/bin/env node
// lib/patch-pi-backspace-tab.sh
// Idempotent fix for pi's backspace/tab double-fire bug.
//
// When Kitty keyboard protocol flag 2 (event types) is active, some terminals
// emit raw 0x7f / 0x09 bytes on *both* keydown and keyup for Backspace/Tab,
// instead of sending keyup as a CSI-u release sequence.  Since isKeyRelease()
// only detects CSI-u :3 markers, both events pass through and double-fire.
//
// This patch adds a ~150ms dedup window in StdinBuffer.emitDataSequence()
// that drops the second occurrence of the same raw byte.
//
// Idempotent — safe to run repeatedly.  No-op if already applied.

const fs = require("fs");
const path = require("path");
const os = require("os");
const { execSync } = require("child_process");

// ── Find pi's real installation prefix ─────────────────────────────────
// pi is typically at ~/.local/share/pi-node/node-vX.Y.Z-linux-x64/bin/pi
// We need: <prefix>/lib/node_modules/@earendil-works/pi-coding-agent/...
function findPiPrefix() {
  // Try: which pi → dirname twice to get prefix (bin/pi → prefix)
  try {
    const piBin = execSync("which pi 2>/dev/null || echo ''", { encoding: "utf8" }).trim();
    if (piBin) return path.resolve(piBin, "../..");
  } catch (_) { /* fall through */ }

  // Fallback: glob ~/.local/share/pi-node/node-v*/
  const base = path.join(os.homedir(), ".local", "share", "pi-node");
  try {
    const entries = fs.readdirSync(base);
    const nodeDir = entries.find(e => e.startsWith("node-v"));
    if (nodeDir) return path.join(base, nodeDir);
  } catch (_) { /* fall through */ }

  return null;
}

const prefix = findPiPrefix();
if (!prefix) {
  console.log("patch-pi-backspace-tab: pi installation not found — skipping");
  process.exit(0);
}

const TARGET = path.join(
  prefix,
  "lib", "node_modules",
  "@earendil-works", "pi-coding-agent", "node_modules",
  "@earendil-works", "pi-tui", "dist", "stdin-buffer.js"
);

if (!fs.existsSync(TARGET)) {
  console.log("patch-pi-backspace-tab: target not found at " + TARGET + " — skipping");
  process.exit(0);
}

let src = fs.readFileSync(TARGET, "utf8");

if (src.includes("_lastRawByte")) {
  console.log("patch-pi-backspace-tab: fix already present — skipping");
  process.exit(0);
}

console.log("patch-pi-backspace-tab: applying fix to " + TARGET);

// Backup
const ts = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
fs.copyFileSync(TARGET, TARGET + ".bak-" + ts);

// ── Patch 1: add perf_hooks import ─────────────────────────────────────
if (!src.includes('import { performance }')) {
  src = src.replace(
    'import { EventEmitter } from "events";',
    'import { EventEmitter } from "events";\nimport { performance } from "node:perf_hooks";'
  );
}

// ── Patch 2: add class fields ──────────────────────────────────────────
src = src.replace(
  "    pendingLegacyPrintableCodepoint;",
  `    pendingLegacyPrintableCodepoint;
    // Dedup raw bytes that arrive as keydown+keyup pairs (terminal bug with Kitty protocol)
    // Affected keys: backspace (0x7f), tab (0x09)
    _lastRawByte = -1;
    _lastRawByteTime = 0;
    static RAW_KEYUP_DEDUP_WINDOW_MS = 150;`
);

// ── Patch 3: dedup logic in emitDataSequence ───────────────────────────
const dedupBlock = `
                // Dedup raw key-up events that some terminals incorrectly emit as
                // raw bytes instead of Kitty CSI-u release sequences.
                // Backspace (0x7f) and Tab (0x09) are affected when Kitty keyboard
                // protocol flag 2 (event types) is active.
                if (rawCp === 0x7f || rawCp === 0x09) {
                    const now = performance.now();
                    if (rawCp === this._lastRawByte &&
                        (now - this._lastRawByteTime) < StdinBuffer.RAW_KEYUP_DEDUP_WINDOW_MS) {
                        // Key-up duplicate — drop it
                        this._lastRawByte = -1;
                        this._lastRawByteTime = 0;
                        return;
                    }
                    this._lastRawByte = rawCp;
                    this._lastRawByteTime = now;
                } else {
                    this._lastRawByte = -1;
                    this._lastRawByteTime = 0;
                }`;

src = src.replace(
  "                this.pendingLegacyPrintableCodepoint = rawCp;",
  "                this.pendingLegacyPrintableCodepoint = rawCp;" + dedupBlock
);

// ── Patch 4: in the "else" branch of emitDataSequence, clear dedup state ─
src = src.replace(
  "            this.pendingKittyPrintableCodepoint = undefined;\n        }",
  "            this.pendingKittyPrintableCodepoint = undefined;\n            this._lastRawByte = -1;\n            this._lastRawByteTime = 0;\n        }"
);

// ── Patch 5: flush() — after pendingLegacyPrintableCodepoint = undefined ─
src = src.replace(
  "        this.pendingLegacyPrintableCodepoint = undefined;\n        return sequences;",
  "        this.pendingLegacyPrintableCodepoint = undefined;\n        this._lastRawByte = -1;\n        this._lastRawByteTime = 0;\n        return sequences;"
);

// ── Patch 6: clear() — after pendingLegacyPrintableCodepoint = undefined ─
src = src.replace(
  "        this.pendingLegacyPrintableCodepoint = undefined;\n    }",
  "        this.pendingLegacyPrintableCodepoint = undefined;\n        this._lastRawByte = -1;\n        this._lastRawByteTime = 0;\n    }"
);

fs.writeFileSync(TARGET, src, "utf8");
console.log("patch-pi-backspace-tab: fix applied successfully");
