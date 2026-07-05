/**
 * Strict Read-Only Mode Extension for pi
 *
 * Features:
 * - Limits tools to read-only set via setActiveTools()
 * - Silently blocks edit/write and destructive bash commands (no UI selects or lists)
 * - Injects hidden context to guide the model
 * - Minimal status indicator only
 * - Persists across sessions
 * - Toggle with /readonly or start with --readonly
 *
 * No plan extraction, no todo lists, no choice dialogs, no "disable mode" prompts.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const READONLY_TOOLS = ["read", "bash", "grep", "find", "ls", "question"] as const;
const FULL_TOOLS = ["read", "bash", "edit", "write", "grep", "find", "ls"] as const;

// Destructive patterns (expanded from plan-mode example)
const DESTRUCTIVE_PATTERNS = [
  /\brm(\s+-[rf]+)?\b/i,
  /\bmv\b/i,
  /\bcp\b/i,
  /\bmkdir\b/i,
  /\btouch\b/i,
  /\bchmod\b/i,
  /\bchown\b/i,
  /\brmdir\b/i,
  /\btee\b/i,
  /\bgit\s+(add|commit|push|pull|merge|rebase|reset|checkout\s+-b|stash|cherry-pick)/i,
  /\b(npm|yarn|pnpm|pip)\s+(install|add|remove|uninstall|update|ci)/i,
  /\bsudo\b/i,
  /\bsu\b/i,
  /\bkill|killall|pkill\b/i,
  /\b(reboot|shutdown|systemctl\s+(start|stop|restart))/i,
  /\b(vim?|nano|emacs|code|subl)\b/i,
  /(^|[^<])>(?!>)/, // redirect
  />>/,
];

function isSafeReadOnlyCommand(command: string): boolean {
  return !DESTRUCTIVE_PATTERNS.some((pattern) => pattern.test(command));
}

export default function readonlyMode(pi: ExtensionAPI): void {
  let enabled = false;

  function updateStatus(ctx: ExtensionContext): void {
    ctx.ui.setStatus(
      "readonly-mode",
      enabled
        ? ctx.ui.theme.fg("warning", "🔒 readonly")
        : undefined
    );
  }

  function persistState(): void {
    pi.appendEntry("readonly-mode", { enabled });
  }

  function toggleReadonly(ctx: ExtensionContext): void {
    enabled = !enabled;

    if (enabled) {
      pi.setActiveTools([...READONLY_TOOLS]);
      ctx.ui.notify("🔒 Read-only mode ENABLED (writes blocked)", "warning");
    } else {
      pi.setActiveTools([...FULL_TOOLS]);
      ctx.ui.notify("Read-only mode disabled. Full tools restored.", "info");
    }

    updateStatus(ctx);
    persistState();
  }

  // CLI flag
  pi.registerFlag("readonly", {
    description: "Start session in strict read-only mode",
    type: "boolean",
    default: false,
  });

  // Command to toggle
  pi.registerCommand("readonly", {
    description: "Toggle strict read-only mode",
    handler: async (_args, ctx) => toggleReadonly(ctx),
  });

  // Block write operations and unsafe bash (no UI interaction)
  pi.on("tool_call", async (event, ctx) => {
    if (!enabled) return undefined;

    const toolName = event.toolName;

    if (toolName === "edit" || toolName === "write") {
      return {
        block: true,
        reason: "Read-only mode active: File modifications (edit/write) are disabled.",
      };
    }

    if (toolName === "bash") {
      const command = String(event.input?.command || "");
      if (!isSafeReadOnlyCommand(command)) {
        return {
          block: true,
          reason: `Read-only mode: This command is not permitted.\n\nCommand: ${command}\n\nOnly inspection commands (cat, ls, grep, find, git status/log/diff, etc.) are allowed.`,
        };
      }
    }

    return undefined;
  });

  // Inject hidden guidance for the model
  pi.on("before_agent_start", async () => {
    if (!enabled) return undefined;

    return {
      message: {
        customType: "readonly-mode-context",
        content: `=== STRICT READ-ONLY MODE ACTIVE ===
You are operating under strict read-only constraints:
- Allowed tools: ${READONLY_TOOLS.join(", ")}
- You may ONLY read, inspect, search, and run safe diagnostic commands.
- You MUST NOT attempt edit, write, rm, mv, git commit, installs, or any file/system modifications.
- If the task requires changes, clearly state this and ask the user to run "/readonly" to exit read-only mode.

Focus on analysis, exploration, and planning. Do not output tool calls for prohibited actions.`,
        display: false,
      },
    };
  });

  // Restore state on session start/resume
  pi.on("session_start", async (_event, ctx) => {
    // Check CLI flag
    if (pi.getFlag("readonly") === true) {
      enabled = true;
    }

    // Restore from persisted custom entries (last one wins)
    const entries = ctx.sessionManager.getEntries();
    const lastStateEntry = entries
      .filter((e: any) => e.type === "custom" && e.customType === "readonly-mode")
      .pop();

    if (lastStateEntry?.data?.enabled !== undefined) {
      enabled = lastStateEntry.data.enabled;
    }

    if (enabled) {
      pi.setActiveTools([...READONLY_TOOLS]);
    }

    updateStatus(ctx);
    persistState(); // Ensure state is saved
  });

  // Persist after turns in case state changed
  pi.on("turn_end", async () => {
    persistState();
  });
}
