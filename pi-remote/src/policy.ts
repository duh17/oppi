/**
 * Policy engine — evaluates tool calls against user rules.
 *
 * Layered evaluation order:
 * 1. Hard denies (immutable, can't be overridden)
 * 2. Workspace boundary checks
 * 3. User rules (evaluated in order)
 * 4. Default action
 */

import { minimatch } from "minimatch";

// ─── Types ───

export type PolicyAction = "allow" | "ask" | "deny";
export type RiskLevel = "low" | "medium" | "high" | "critical";

export interface PolicyRule {
  tool?: string;         // "bash" | "write" | "edit" | "read" | "*"
  exec?: string;         // For bash: executable name ("git", "rm", "sudo")
  pattern?: string;      // Glob against command or path
  pathWithin?: string;   // Path must be inside this directory
  action: PolicyAction;
  label?: string;
  risk?: RiskLevel;
}

export interface PolicyPreset {
  name: string;
  hardDeny: PolicyRule[];
  rules: PolicyRule[];
  defaultAction: PolicyAction;
}

export interface PolicyDecision {
  action: PolicyAction;
  reason: string;
  risk: RiskLevel;
  layer: "hard_deny" | "rule" | "default";
  ruleLabel?: string;
}

export interface GateRequest {
  tool: string;
  input: Record<string, unknown>;
  toolCallId: string;
}

// ─── Bash Command Parsing ───

export interface ParsedCommand {
  executable: string;
  args: string[];
  raw: string;
  hasPipe: boolean;
  hasRedirect: boolean;
  hasSubshell: boolean;
}

/**
 * Parse a bash command string into structured form.
 * Not a full shell parser — handles the common cases for policy matching.
 */
export function parseBashCommand(command: string): ParsedCommand {
  const raw = command.trim();
  const hasPipe = /(?<![\\])\|/.test(raw);
  const hasRedirect = /(?<![\\])[><]/.test(raw);
  const hasSubshell = /\$\(/.test(raw) || /`[^`]+`/.test(raw);

  // Split on first whitespace to get executable
  // Handle leading env vars (VAR=val cmd ...) and command prefixes
  let cmdPart = raw;

  // Strip leading env assignments (FOO=bar BAZ=qux cmd ...)
  while (/^\w+=\S+\s/.test(cmdPart)) {
    cmdPart = cmdPart.replace(/^\w+=\S+\s+/, "");
  }

  // Handle common prefixes
  const prefixes = ["command", "builtin", "env", "nice", "nohup", "time"];
  for (const prefix of prefixes) {
    if (cmdPart.startsWith(prefix + " ")) {
      cmdPart = cmdPart.slice(prefix.length).trimStart();
    }
  }

  // Split into tokens (basic: split on whitespace, respect quotes)
  const tokens = tokenize(cmdPart);
  const executable = tokens[0] || raw;
  const args = tokens.slice(1);

  return { executable, args, raw, hasPipe, hasRedirect, hasSubshell };
}

/**
 * Match a bash command string against a glob-like pattern.
 *
 * Unlike minimatch (designed for file paths where '*' doesn't cross '/'),
 * this treats the command as a flat string where '*' matches any characters
 * including '/'. This ensures 'rm *-*r*' matches 'rm -rf /tmp/foo'.
 *
 * Supports: '*' (match anything), literal characters.
 * Does NOT support: '?', '**', character classes.
 */
export function matchBashPattern(command: string, pattern: string): boolean {
  // Convert glob pattern to regex: escape regex specials, then replace * with .*
  const escaped = pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  const regexStr = "^" + escaped.replace(/\*/g, ".*") + "$";
  return new RegExp(regexStr).test(command);
}

/**
 * Basic shell tokenizer — splits on whitespace, respects single/double quotes.
 */
function tokenize(input: string): string[] {
  const tokens: string[] = [];
  let current = "";
  let inSingle = false;
  let inDouble = false;
  let escaped = false;

  for (const ch of input) {
    if (escaped) {
      current += ch;
      escaped = false;
      continue;
    }
    if (ch === "\\") {
      escaped = true;
      continue;
    }
    if (ch === "'" && !inDouble) {
      inSingle = !inSingle;
      continue;
    }
    if (ch === '"' && !inSingle) {
      inDouble = !inDouble;
      continue;
    }
    if ((ch === " " || ch === "\t") && !inSingle && !inDouble) {
      if (current) {
        tokens.push(current);
        current = "";
      }
      continue;
    }
    current += ch;
  }
  if (current) tokens.push(current);
  return tokens;
}

// ─── Presets ───

/**
 * Container preset — the default for pi-remote.
 *
 * Philosophy: the Apple container IS the security boundary.
 * The policy only gates things the container can't protect against:
 * - Credential exfiltration (API keys synced into container)
 * - Destructive operations on bind-mounted workspace data
 * - Escape attempts (sudo, privilege escalation)
 *
 * Everything else flows through. This mirrors how pi's permission-gate
 * works on mac-studio (regex-matched dangerous patterns only), but even
 * more permissive because there's no host system to damage.
 */
export const PRESET_CONTAINER: PolicyPreset = {
  name: "container",
  hardDeny: [
    // Privilege escalation — can't escape container, but deny on principle
    { tool: "bash", exec: "sudo", action: "deny", label: "No sudo", risk: "critical" },
    { tool: "bash", exec: "doas", action: "deny", label: "No doas", risk: "critical" },
    { tool: "bash", pattern: "su -*root*", action: "deny", label: "No su root", risk: "critical" },

    // Credential exfiltration — API keys are synced into ~/.pi/agent/auth.json
    { tool: "bash", pattern: "*auth.json*", action: "deny", label: "Protect API keys", risk: "critical" },
    { tool: "read", pattern: "**/agent/auth.json", action: "deny", label: "Protect API keys", risk: "critical" },
    { tool: "bash", pattern: "*printenv*_KEY*", action: "deny", label: "Protect env secrets", risk: "critical" },
    { tool: "bash", pattern: "*printenv*_SECRET*", action: "deny", label: "Protect env secrets", risk: "critical" },
    { tool: "bash", pattern: "*printenv*_TOKEN*", action: "deny", label: "Protect env secrets", risk: "critical" },

    // Fork bomb
    { tool: "bash", pattern: "*:(){ :|:& };*", action: "deny", label: "Fork bomb", risk: "critical" },
  ],
  rules: [
    // ── Destructive operations → ask ──
    // These can damage bind-mounted workspace data

    // rm with force/recursive flags
    { tool: "bash", exec: "rm", pattern: "rm *-*r*", action: "ask", label: "Recursive delete", risk: "high" },
    { tool: "bash", exec: "rm", pattern: "rm *-*f*", action: "ask", label: "Force delete", risk: "high" },

    // Git destructive operations
    { tool: "bash", exec: "git", pattern: "git push*--force*", action: "ask", label: "Force push", risk: "high" },
    { tool: "bash", exec: "git", pattern: "git push*-f*", action: "ask", label: "Force push", risk: "high" },
    { tool: "bash", exec: "git", pattern: "git reset --hard*", action: "ask", label: "Hard reset", risk: "high" },
    { tool: "bash", exec: "git", pattern: "git clean*-*f*", action: "ask", label: "Git clean", risk: "high" },

    // Pipe to shell — matched structurally in evaluate(), not by glob.
    // (Glob patterns can't express "curl ... | sh" reliably.)
  ],
  // Container provides isolation — allow by default
  defaultAction: "allow",
};

/**
 * Restricted preset — read-only, no execution.
 * For untrusted users or demo mode.
 */
export const PRESET_RESTRICTED: PolicyPreset = {
  name: "restricted",
  hardDeny: [
    { tool: "bash", action: "deny", label: "No bash", risk: "critical" },
    { tool: "write", action: "deny", label: "No writes", risk: "high" },
    { tool: "edit", action: "deny", label: "No edits", risk: "high" },
  ],
  rules: [
    { tool: "read", action: "allow", risk: "low" },
    { tool: "grep", action: "allow", risk: "low" },
    { tool: "find", action: "allow", risk: "low" },
    { tool: "ls", action: "allow", risk: "low" },
  ],
  defaultAction: "deny",
};

export const PRESETS: Record<string, PolicyPreset> = {
  container: PRESET_CONTAINER,
  restricted: PRESET_RESTRICTED,
};

// ─── Policy Engine ───

export class PolicyEngine {
  private preset: PolicyPreset;

  constructor(presetName: string = "container") {
    const preset = PRESETS[presetName];
    if (!preset) {
      throw new Error(`Unknown policy preset: ${presetName}. Available: ${Object.keys(PRESETS).join(", ")}`);
    }
    this.preset = preset;
  }

  /**
   * Evaluate a tool call against the policy.
   *
   * Layered evaluation:
   * 1. Hard denies (immutable — credential exfiltration, privilege escalation)
   * 2. Rules (destructive operations on workspace data)
   * 3. Default action (allow for container preset)
   *
   * Pipes and subshells are NOT auto-escalated. The container is the
   * security boundary — `grep foo | wc -l` shouldn't need phone approval.
   */
  evaluate(req: GateRequest): PolicyDecision {
    const { tool, input } = req;

    // Layer 1: Hard denies (immutable)
    for (const rule of this.preset.hardDeny) {
      if (this.matchesRule(rule, tool, input)) {
        return {
          action: "deny",
          reason: rule.label || "Blocked by hard deny rule",
          risk: rule.risk || "critical",
          layer: "hard_deny",
          ruleLabel: rule.label,
        };
      }
    }

    // Layer 1.5: Pipe-to-shell detection (structural, not glob-based)
    // curl/wget piped to sh/bash is remote code execution — always ask.
    if (tool === "bash") {
      const command = (input as { command?: string }).command || "";
      const parsed = parseBashCommand(command);
      if (parsed.hasPipe && /\|\s*(ba)?sh\b/.test(command)) {
        const downloader = parsed.executable;
        if (downloader === "curl" || downloader === "wget") {
          return {
            action: "ask",
            reason: "Pipe to shell (remote code execution)",
            risk: "high",
            layer: "rule",
            ruleLabel: "Pipe to shell",
          };
        }
      }
    }

    // Layer 2: Rules (destructive operations)
    for (const rule of this.preset.rules) {
      if (this.matchesRule(rule, tool, input)) {
        return {
          action: rule.action,
          reason: rule.label || `Matched rule for ${tool}`,
          risk: rule.risk || "medium",
          layer: "rule",
          ruleLabel: rule.label,
        };
      }
    }

    // Layer 3: Default
    return {
      action: this.preset.defaultAction,
      reason: "No matching rule — using default",
      risk: "low",
      layer: "default",
    };
  }

  /**
   * Get a human-readable summary of a tool call for display on phone.
   */
  formatDisplaySummary(req: GateRequest): string {
    const { tool, input } = req;

    switch (tool) {
      case "bash":
        return (input as { command?: string }).command || "bash (unknown command)";
      case "read":
        return `Read ${(input as { path?: string }).path || "unknown file"}`;
      case "write":
        return `Write ${(input as { path?: string }).path || "unknown file"}`;
      case "edit":
        return `Edit ${(input as { path?: string }).path || "unknown file"}`;
      case "grep":
        return `Grep for "${(input as { pattern?: string }).pattern || "?"}"`;
      case "find":
        return `Find in ${(input as { path?: string }).path || "."}`;
      case "ls":
        return `List ${(input as { path?: string }).path || "."}`;
      default:
        return `${tool}(${JSON.stringify(input).slice(0, 100)})`;
    }
  }

  getPresetName(): string {
    return this.preset.name;
  }

  // ─── Internal ───

  private matchesRule(rule: PolicyRule, tool: string, input: Record<string, unknown>): boolean {
    // Check tool name
    if (rule.tool && rule.tool !== "*" && rule.tool !== tool) {
      return false;
    }

    // Check executable (bash only)
    if (rule.exec && tool === "bash") {
      const command = (input as { command?: string }).command || "";
      const parsed = parseBashCommand(command);
      if (parsed.executable !== rule.exec) {
        return false;
      }
    } else if (rule.exec && tool !== "bash") {
      // exec field only applies to bash
      return false;
    }

    // Check pattern against the match target.
    if (rule.pattern) {
      const target = this.getMatchTarget(tool, input);

      if (tool === "bash") {
        // Bash commands are strings, not file paths. minimatch treats '/' as
        // a path separator so '*' won't cross it — 'rm *-*r*' fails to match
        // 'rm -rf /tmp/foo'. Convert the glob to a simple regex instead.
        if (!matchBashPattern(target, rule.pattern)) {
          return false;
        }
      } else {
        // For file-path tools (read, write, edit), minimatch is appropriate.
        if (!minimatch(target, rule.pattern, { dot: true })) {
          return false;
        }
      }
    }

    // Check pathWithin (path confinement)
    if (rule.pathWithin) {
      const paths = this.extractPaths(tool, input);
      if (paths.length > 0) {
        const confined = paths.every(p => p.startsWith(rule.pathWithin!));
        if (!confined) return false;
      }
    }

    return true;
  }

  private getMatchTarget(tool: string, input: Record<string, unknown>): string {
    switch (tool) {
      case "bash":
        return (input as { command?: string }).command || "";
      case "grep":
        return (input as { pattern?: string }).pattern || "";
      case "read":
      case "write":
      case "edit":
      case "find":
      case "ls":
        return (input as { path?: string }).path || "";
      default:
        return JSON.stringify(input);
    }
  }

  private extractPaths(tool: string, input: Record<string, unknown>): string[] {
    switch (tool) {
      case "read":
      case "write":
      case "edit":
      case "find":
      case "ls": {
        const path = (input as { path?: string }).path;
        return path ? [path] : [];
      }
      case "bash":
        // For v1, skip path confinement on bash (covered by exec matching)
        return [];
      default:
        return [];
    }
  }
}
