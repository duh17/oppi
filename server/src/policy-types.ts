import type { Rule } from "./rules.js";

export type PolicyAction = "allow" | "ask" | "deny";

export interface PolicyRule {
  tool?: string; // "bash" | "write" | "edit" | "read" | "*"
  exec?: string; // For bash: executable name ("git", "rm", "sudo")
  pattern?: string; // Glob against command or path
  pathWithin?: string; // Path must be inside this directory
  domain?: string; // Host/domain matcher
  action: PolicyAction;
  label?: string;
}

/** Resolved heuristic actions (false = disabled). */
export interface ResolvedHeuristics {
  pipeToShell: PolicyAction | false;
  dataEgress: PolicyAction | false;
  secretEnvInUrl: PolicyAction | false;
  secretFileAccess: PolicyAction | false;
}

export interface CompiledPolicy {
  name: string;
  hardDeny: PolicyRule[];
  rules: PolicyRule[];
  defaultAction: PolicyAction;
  heuristics: ResolvedHeuristics;
}

export interface PolicyDecision {
  action: PolicyAction;
  reason: string;
  layer:
    | "hard_deny"
    | "learned_deny"
    | "session_rule"
    | "workspace_rule"
    | "global_rule"
    | "rule"
    | "default";
  ruleLabel?: string;
  ruleId?: string; // ID of the learned rule that matched (if any)
}

export interface GateRequest {
  tool: string;
  input: Record<string, unknown>;
  toolCallId: string;
}

export interface ParsedCommand {
  executable: string;
  args: string[];
  raw: string;
  hasPipe: boolean;
  hasRedirect: boolean;
  hasSubshell: boolean;
}

export interface PathAccess {
  path: string; // Directory path (resolved, no ~ )
  access: "read" | "readwrite";
}

/**
 * Per-session policy configuration, derived from workspace settings.
 * Controls which directories are accessible and at what level.
 */
export interface PolicyConfig {
  /** Directories the session may access. Order doesn't matter. */
  allowedPaths: PathAccess[];

  /**
   * Extra executables to auto-allow for this workspace.
   * Use for dev runtimes (node, python3, make, cargo, etc.) that need
   * to run in a specific workspace but CAN execute arbitrary code.
   *
   * These are NOT in the global read-only list because they're code executors.
   * A workspace for a Node.js project might add ["node", "npx", "npm"].
   * A workspace for a Python project might add ["python3", "uv", "pip"].
   */
  allowedExecutables?: string[];
}

export function matcherTypeRank(rule: Rule): number {
  if (rule.pattern && rule.executable) return 3;
  if (rule.pattern) return 2;
  if (rule.executable) return 1;
  return 0;
}

export function literalPrefixLength(pattern: string): number {
  let length = 0;
  for (let i = 0; i < pattern.length; i++) {
    const ch = pattern[i];
    if (ch === "*" || ch === "?" || ch === "[" || ch === "{") {
      break;
    }
    length += 1;
  }
  return length;
}
