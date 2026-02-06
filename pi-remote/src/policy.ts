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

export const PRESET_ADMIN: PolicyPreset = {
  name: "admin",
  hardDeny: [
    { tool: "bash", pattern: "rm -rf /", action: "deny", label: "Prevent rm -rf /", risk: "critical" },
    { tool: "bash", exec: "sudo", action: "deny", label: "No sudo", risk: "critical" },
    { tool: "bash", pattern: "*/.ssh/*", action: "deny", label: "Protect SSH keys", risk: "critical" },
    { tool: "write", pattern: "*/.ssh/*", action: "deny", label: "Protect SSH keys", risk: "critical" },
    { tool: "edit", pattern: "*/.ssh/*", action: "deny", label: "Protect SSH keys", risk: "critical" },
    { tool: "bash", pattern: "**/.env*", action: "deny", label: "Protect env files", risk: "high" },
    { tool: "write", pattern: "**/.env*", action: "deny", label: "Protect env files", risk: "high" },
    { tool: "edit", pattern: "**/.env*", action: "deny", label: "Protect env files", risk: "high" },
    { tool: "write", pattern: ".env*", action: "deny", label: "Protect env files", risk: "high" },
    { tool: "edit", pattern: ".env*", action: "deny", label: "Protect env files", risk: "high" },
  ],
  rules: [
    // Safe reads
    { tool: "read", action: "allow", label: "Read files", risk: "low" },
    { tool: "grep", action: "allow", label: "Grep", risk: "low" },
    { tool: "find", action: "allow", label: "Find", risk: "low" },
    { tool: "ls", action: "allow", label: "List files", risk: "low" },

    // Safe bash commands
    { tool: "bash", exec: "ls", action: "allow", risk: "low" },
    { tool: "bash", exec: "cat", action: "allow", risk: "low" },
    { tool: "bash", exec: "head", action: "allow", risk: "low" },
    { tool: "bash", exec: "tail", action: "allow", risk: "low" },
    { tool: "bash", exec: "wc", action: "allow", risk: "low" },
    { tool: "bash", exec: "echo", action: "allow", risk: "low" },
    { tool: "bash", exec: "grep", action: "allow", risk: "low" },
    { tool: "bash", exec: "rg", action: "allow", risk: "low" },
    { tool: "bash", exec: "find", action: "allow", risk: "low" },
    { tool: "bash", exec: "which", action: "allow", risk: "low" },
    { tool: "bash", exec: "pwd", action: "allow", risk: "low" },
    { tool: "bash", exec: "date", action: "allow", risk: "low" },
    { tool: "bash", exec: "uname", action: "allow", risk: "low" },
    { tool: "bash", exec: "whoami", action: "allow", risk: "low" },
    { tool: "bash", exec: "hostname", action: "allow", risk: "low" },
    { tool: "bash", exec: "basename", action: "allow", risk: "low" },
    { tool: "bash", exec: "dirname", action: "allow", risk: "low" },
    { tool: "bash", exec: "realpath", action: "allow", risk: "low" },
    { tool: "bash", exec: "stat", action: "allow", risk: "low" },
    { tool: "bash", exec: "file", action: "allow", risk: "low" },
    { tool: "bash", exec: "diff", action: "allow", risk: "low" },
    { tool: "bash", exec: "sort", action: "allow", risk: "low" },
    { tool: "bash", exec: "uniq", action: "allow", risk: "low" },
    { tool: "bash", exec: "cut", action: "allow", risk: "low" },
    { tool: "bash", exec: "tr", action: "allow", risk: "low" },
    { tool: "bash", exec: "sed", action: "allow", risk: "low" },
    { tool: "bash", exec: "awk", action: "allow", risk: "low" },
    { tool: "bash", exec: "jq", action: "allow", risk: "low" },
    { tool: "bash", exec: "ast-grep", action: "allow", risk: "low" },

    // Safe git (read-only)
    { tool: "bash", exec: "git", pattern: "git status*", action: "allow", risk: "low" },
    { tool: "bash", exec: "git", pattern: "git diff*", action: "allow", risk: "low" },
    { tool: "bash", exec: "git", pattern: "git log*", action: "allow", risk: "low" },
    { tool: "bash", exec: "git", pattern: "git branch*", action: "allow", risk: "low" },
    { tool: "bash", exec: "git", pattern: "git show*", action: "allow", risk: "low" },
    { tool: "bash", exec: "git", pattern: "git rev-parse*", action: "allow", risk: "low" },
    { tool: "bash", exec: "git", pattern: "git ls-files*", action: "allow", risk: "low" },

    // Mutating git — ask
    { tool: "bash", exec: "git", action: "ask", label: "Git mutation", risk: "medium" },

    // Build tools — ask
    { tool: "bash", exec: "npm", action: "ask", label: "npm command", risk: "medium" },
    { tool: "bash", exec: "npx", action: "ask", label: "npx command", risk: "medium" },
    { tool: "bash", exec: "pnpm", action: "ask", label: "pnpm command", risk: "medium" },
    { tool: "bash", exec: "yarn", action: "ask", label: "yarn command", risk: "medium" },
    { tool: "bash", exec: "cargo", action: "ask", label: "cargo command", risk: "medium" },
    { tool: "bash", exec: "make", action: "ask", label: "make command", risk: "medium" },
    { tool: "bash", exec: "uv", action: "ask", label: "uv command", risk: "medium" },
    { tool: "bash", exec: "pip", action: "ask", label: "pip command", risk: "medium" },
    { tool: "bash", exec: "go", action: "ask", label: "go command", risk: "medium" },

    // Writes — ask (safe but worth confirming for non-trivial cases)
    { tool: "write", action: "ask", label: "Write file", risk: "medium" },
    { tool: "edit", action: "ask", label: "Edit file", risk: "medium" },

    // Pipes and subshells — always ask
    // (These are caught by the structural check in evaluate(), but explicit rule for clarity)
  ],
  defaultAction: "ask",
};

export const PRESET_STANDARD: PolicyPreset = {
  name: "standard",
  hardDeny: [
    { tool: "bash", exec: "sudo", action: "deny", label: "No sudo", risk: "critical" },
    { tool: "bash", exec: "rm", action: "deny", label: "No rm", risk: "high" },
    { tool: "bash", exec: "curl", action: "deny", label: "No curl", risk: "high" },
    { tool: "bash", exec: "wget", action: "deny", label: "No wget", risk: "high" },
    { tool: "bash", pattern: "*/.ssh/*", action: "deny", label: "Protect SSH", risk: "critical" },
    { tool: "write", pattern: "*/.ssh/*", action: "deny", label: "Protect SSH", risk: "critical" },
    { tool: "edit", pattern: "*/.ssh/*", action: "deny", label: "Protect SSH", risk: "critical" },
  ],
  rules: [
    { tool: "read", action: "allow", risk: "low" },
    { tool: "grep", action: "allow", risk: "low" },
    { tool: "find", action: "allow", risk: "low" },
    { tool: "ls", action: "allow", risk: "low" },
    { tool: "bash", exec: "ls", action: "allow", risk: "low" },
    { tool: "bash", exec: "cat", action: "allow", risk: "low" },
    { tool: "bash", exec: "head", action: "allow", risk: "low" },
    { tool: "bash", exec: "tail", action: "allow", risk: "low" },
    { tool: "bash", exec: "grep", action: "allow", risk: "low" },
    { tool: "bash", exec: "rg", action: "allow", risk: "low" },
    { tool: "bash", exec: "find", action: "allow", risk: "low" },
    { tool: "bash", exec: "wc", action: "allow", risk: "low" },
  ],
  defaultAction: "ask",
};

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
  admin: PRESET_ADMIN,
  standard: PRESET_STANDARD,
  restricted: PRESET_RESTRICTED,
};

// ─── Policy Engine ───

export class PolicyEngine {
  private preset: PolicyPreset;

  constructor(presetName: string = "admin") {
    const preset = PRESETS[presetName];
    if (!preset) {
      throw new Error(`Unknown policy preset: ${presetName}. Available: ${Object.keys(PRESETS).join(", ")}`);
    }
    this.preset = preset;
  }

  /**
   * Evaluate a tool call against the policy.
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

    // Layer 1.5: Structural hazard check for bash
    if (tool === "bash") {
      const command = (input as { command?: string }).command || "";
      const parsed = parseBashCommand(command);

      if (parsed.hasSubshell) {
        return {
          action: "ask",
          reason: "Command contains subshell expansion",
          risk: "high",
          layer: "hard_deny",
          ruleLabel: "Subshell detected",
        };
      }

      if (parsed.hasPipe) {
        return {
          action: "ask",
          reason: "Command contains pipe",
          risk: "medium",
          layer: "hard_deny",
          ruleLabel: "Pipe detected",
        };
      }
    }

    // Layer 2: User rules (in order)
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
      risk: "medium",
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

    // Check pattern (glob match against the match target)
    if (rule.pattern) {
      const target = this.getMatchTarget(tool, input);
      if (!minimatch(target, rule.pattern, { dot: true })) {
        return false;
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
