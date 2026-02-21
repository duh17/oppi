/**
 * Policy engine — evaluates tool calls against rule data + heuristics.
 *
 * Effective order in evaluateWithRules():
 * 1. Reserved guards (policy.* always ask)
 * 2. Heuristics-as-code
 * 3. User rules (deny-first, then most-specific)
 * 4. Default policy fallback
 */

import { existsSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { normalize as pathNormalize, resolve as pathResolve } from "node:path";
import { globMatch } from "./glob.js";
import {
  matchBashPattern,
  parseBashCommand,
  splitBashCommandChain,
  splitPipelineStages,
} from "./policy-bash.js";
import {
  evaluateConfiguredHeuristics,
  hasSecretEnvExpansionInUrl,
  hasSecretFileReference,
  isDataEgress,
  isSecretFileRead,
} from "./policy-heuristics.js";
import {
  addDomainToAllowlist,
  listAllowlistDomains,
  loadFetchAllowlist,
  removeDomainFromAllowlist,
} from "./policy-allowlist.js";
import {
  compileDeclarativePolicy,
  defaultPolicy,
  defaultPresetRules,
  policyRulesFromDeclarativeConfig,
  policyRuntimeConfig,
  resolveBuiltInPolicy,
} from "./policy-presets.js";
import { literalPrefixLength, matcherTypeRank } from "./policy-types.js";
import type { Rule } from "./rules.js";
import type { PolicyConfig as DeclarativePolicyConfig } from "./types.js";
import type {
  CompiledPolicy,
  GateRequest,
  PolicyConfig,
  PolicyDecision,
  PolicyRule,
} from "./policy-types.js";

export {
  addDomainToAllowlist,
  listAllowlistDomains,
  loadFetchAllowlist,
  matchBashPattern,
  parseBashCommand,
  splitBashCommandChain,
  splitPipelineStages,
  removeDomainFromAllowlist,
  defaultPolicy,
  defaultPresetRules,
  policyRulesFromDeclarativeConfig,
  policyRuntimeConfig,
  hasSecretEnvExpansionInUrl,
  hasSecretFileReference,
  isDataEgress,
  isSecretFileRead,
};

export type {
  GateRequest,
  PathAccess,
  PolicyAction,
  PolicyConfig,
  PolicyDecision,
  PolicyRule,
  ParsedCommand,
} from "./policy-types.js";

const CHAIN_HELPER_EXECUTABLES = new Set(["cd", "echo", "pwd", "true", "false", ":", "#"]);
const FILE_PATH_TOOLS = new Set(["read", "write", "edit", "find", "ls"]);

function executableName(raw: string): string {
  return raw.includes("/") ? raw.split("/").pop() || raw : raw;
}

function normalizePathInput(rawPath: string): { rawNormalized: string; resolvedRealpath?: string } {
  const expanded = rawPath.replace(/^~(?=$|\/)/, homedir());
  const rawNormalized = pathNormalize(pathResolve(expanded));

  try {
    if (existsSync(rawNormalized)) {
      return { rawNormalized, resolvedRealpath: realpathSync(rawNormalized) };
    }
  } catch {
    // Best-effort only — use normalized raw path.
  }

  return { rawNormalized };
}

interface ParsedRequestContext {
  executable?: string;
  pathRawNormalized?: string;
  pathResolved?: string;
  command?: string;
}

export class PolicyEngine {
  private policy: CompiledPolicy;
  private config: PolicyConfig;

  constructor(policyOrMode: string | DeclarativePolicyConfig = "default", config?: PolicyConfig) {
    if (typeof policyOrMode === "string") {
      // String modes resolve to built-in compiled profiles.
      // Production always passes DeclarativePolicyConfig from JSON.
      const builtInPolicy = resolveBuiltInPolicy(policyOrMode);
      if (!builtInPolicy) {
        // Unknown mode: fall back to compiling the default policy config
        this.policy = compileDeclarativePolicy(defaultPolicy());
      } else {
        this.policy = builtInPolicy;
      }
    } else {
      this.policy = compileDeclarativePolicy(policyOrMode);
    }

    this.config = config || { allowedPaths: [] };
  }

  /**
   * Evaluate a tool call against the policy.
   *
   * Layered evaluation:
   * 1. Hard denies (credential exfiltration, privilege escalation)
   * 2. Rules (destructive operations on workspace data)
   * 3. Default action (allow for built-in presets)
   *
   * Pipes and subshells are NOT auto-escalated. Read-only command composition
   * like `grep foo | wc -l` should not require phone approval.
   */
  evaluate(req: GateRequest): PolicyDecision {
    const { tool, input } = req;

    // Layer 1: Hard denies
    for (const rule of this.policy.hardDeny) {
      if (this.matchesRule(rule, tool, input)) {
        return {
          action: "deny",
          reason: rule.label || "Blocked by hard deny rule",
          layer: "hard_deny",
          ruleLabel: rule.label,
        };
      }
    }

    // Layer 1.5: Structural heuristics (configurable via policy.heuristics)
    const heuristicDecision = evaluateConfiguredHeuristics(req, this.policy.heuristics);
    if (heuristicDecision) {
      return heuristicDecision;
    }

    // Layer 2: Rules (external actions, destructive operations)
    for (const rule of this.policy.rules) {
      if (this.matchesRule(rule, tool, input)) {
        return {
          action: rule.action,
          reason: rule.label || `Matched rule for ${tool}`,
          layer: "rule",
          ruleLabel: rule.label,
        };
      }
    }

    // Layer 3: Default
    return {
      action: this.policy.defaultAction,
      reason: "No matching rule — using default",
      layer: "default",
    };
  }

  /**
   * Get a human-readable summary of a tool call for display on phone.
   */
  formatDisplaySummary(req: GateRequest): string {
    const { tool, input } = req;

    switch (tool) {
      case "bash": {
        const command = (input as { command?: string }).command || "";
        return command || "bash (unknown command)";
      }
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

  // ─── Rule-based evaluation ───

  /**
   * Evaluate a tool call with unified user rules.
   *
   * Layered evaluation:
   *   1. Reserved guards (policy.* tools always ask)
   *   2. Heuristics (structural detection)
   *   3. User rules (deny wins, then most specific non-deny)
   *   4. Default policy fallback
   */
  evaluateWithRules(
    req: GateRequest,
    rules: Rule[],
    sessionId: string,
    workspaceId: string,
  ): PolicyDecision {
    if (req.tool.startsWith("policy.")) {
      return {
        action: "ask",
        reason: "Policy changes always require approval",
        layer: "rule",
        ruleLabel: "policy guard",
      };
    }

    const heuristicDecision = this.evaluateHeuristics(req);
    if (heuristicDecision) {
      return heuristicDecision;
    }

    const parsed = this.parseRequestContext(req);
    const applicable = rules.filter((rule) => this.isRuleApplicable(rule, sessionId, workspaceId));
    const matching = applicable.filter((rule) => this.matchesUserRule(rule, req, parsed));

    if (matching.length === 0) {
      return {
        action: this.policy.defaultAction,
        reason: `No matching rule — using default ${this.policy.defaultAction}`,
        layer: "default",
      };
    }

    const denyMatches = matching.filter((rule) => rule.decision === "deny");
    if (denyMatches.length > 0) {
      const best = this.pickMostSpecificRule(denyMatches);
      return {
        action: "deny",
        reason: best.label || "Denied by rule",
        layer: this.layerForScope(best.scope),
        ruleLabel: best.label,
        ruleId: best.id,
      };
    }

    const best = this.pickMostSpecificRule(matching);
    return {
      action: best.decision,
      reason: best.label || `Matched ${best.scope} rule`,
      layer: this.layerForScope(best.scope),
      ruleLabel: best.label,
      ruleId: best.id,
    };
  }

  private evaluateHeuristics(req: GateRequest): PolicyDecision | null {
    return evaluateConfiguredHeuristics(req, this.policy.heuristics);
  }

  // ─── Rule matching helpers ───

  private parseRequestContext(req: GateRequest): ParsedRequestContext {
    const { tool, input } = req;

    if (tool === "bash") {
      const command = (input as { command?: string }).command || "";

      const segments = splitBashCommandChain(command);
      const parsedSegments = segments
        .map((segment) => parseBashCommand(segment))
        .filter((parsed) => parsed.executable.length > 0);

      const primary =
        parsedSegments.find(
          (parsed) => !CHAIN_HELPER_EXECUTABLES.has(executableName(parsed.executable)),
        ) || parsedSegments[0];

      const executable = primary ? executableName(primary.executable) : undefined;

      return { executable, command };
    }

    if (FILE_PATH_TOOLS.has(tool)) {
      const path = (input as { path?: string }).path;
      if (!path) return {};
      const normalized = normalizePathInput(path);
      return {
        pathRawNormalized: normalized.rawNormalized,
        pathResolved: normalized.resolvedRealpath,
      };
    }

    return {};
  }

  private isRuleApplicable(rule: Rule, sessionId: string, workspaceId: string): boolean {
    if (rule.expiresAt && rule.expiresAt < Date.now()) return false;

    if (rule.scope === "session") {
      return rule.sessionId === sessionId;
    }

    if (rule.scope === "workspace") {
      return rule.workspaceId === workspaceId;
    }

    return rule.scope === "global";
  }

  private matchesUserRule(rule: Rule, req: GateRequest, parsed: ParsedRequestContext): boolean {
    const { tool, input } = req;

    if (rule.tool !== "*" && rule.tool !== tool) {
      return false;
    }

    if (rule.executable) {
      if (!parsed.executable) return false;
      if (parsed.executable !== rule.executable) return false;
    }

    const pattern = rule.pattern;
    if (!pattern) {
      return true;
    }

    if (tool === "bash") {
      const command = parsed.command || (input as { command?: string }).command || "";
      if (command.length === 0) return false;

      // Match bash glob patterns per chain segment so helper prefixes like
      // `cd repo && git commit ...` still match `git commit*` rules.
      const segments = splitBashCommandChain(command);
      return segments.some((segment) => matchBashPattern(segment, pattern));
    }

    if (FILE_PATH_TOOLS.has(tool)) {
      const candidates = [parsed.pathRawNormalized, parsed.pathResolved].filter(
        (value): value is string => Boolean(value && value.length > 0),
      );
      if (candidates.length === 0) return false;
      return candidates.some((path) => globMatch(path, pattern));
    }

    const serialized = JSON.stringify(input);
    return globMatch(serialized, pattern);
  }

  private pickMostSpecificRule(rules: Rule[]): Rule {
    const withIndex = rules.map((rule, index) => ({ rule, index }));

    withIndex.sort((a, b) => {
      const aMatcher = matcherTypeRank(a.rule);
      const bMatcher = matcherTypeRank(b.rule);
      if (aMatcher !== bMatcher) return bMatcher - aMatcher;

      const aPrefix = a.rule.pattern ? literalPrefixLength(a.rule.pattern) : 0;
      const bPrefix = b.rule.pattern ? literalPrefixLength(b.rule.pattern) : 0;
      if (aPrefix !== bPrefix) return bPrefix - aPrefix;

      const aDecisionBias = a.rule.decision === "ask" ? 1 : 0;
      const bDecisionBias = b.rule.decision === "ask" ? 1 : 0;
      if (aDecisionBias !== bDecisionBias) return bDecisionBias - aDecisionBias;

      return a.index - b.index;
    });

    const best = withIndex[0];
    if (!best) {
      throw new Error("pickMostSpecificRule called with empty rule set");
    }

    return best.rule;
  }

  private layerForScope(scope: Rule["scope"]): PolicyDecision["layer"] {
    if (scope === "session") return "session_rule";
    if (scope === "workspace") return "workspace_rule";
    return "global_rule";
  }

  getPolicyMode(): string {
    return this.policy.name;
  }

  getDefaultAction(): PolicyDecision["action"] {
    return this.policy.defaultAction;
  }

  setDefaultAction(action: PolicyDecision["action"]): void {
    this.policy.defaultAction = action;
  }

  // ─── Internal ───

  private matchesRule(rule: PolicyRule, tool: string, input: Record<string, unknown>): boolean {
    // Check tool name
    if (rule.tool && rule.tool !== "*" && rule.tool !== tool) {
      return false;
    }

    if (tool === "bash") {
      const command = (input as { command?: string }).command || "";
      const segments = splitBashCommandChain(command);

      for (const segment of segments) {
        if (this.matchesBashRuleSegment(rule, segment)) {
          return true;
        }
      }

      return false;
    }

    // exec field only applies to bash
    if (rule.exec) {
      return false;
    }

    // Check pattern against the match target.
    if (rule.pattern) {
      const target = this.getMatchTarget(tool, input);

      // For file-path tools (read, write, edit), glob match against path.
      if (!globMatch(target, rule.pattern)) {
        return false;
      }
    }

    // Check pathWithin (path confinement)
    if (rule.pathWithin) {
      const prefix = rule.pathWithin;
      const paths = this.extractPaths(tool, input);
      if (paths.length > 0) {
        const confined = paths.every((p) => p.startsWith(prefix));
        if (!confined) return false;
      }
    }

    return true;
  }

  private matchesBashRuleSegment(rule: PolicyRule, segment: string): boolean {
    if (rule.exec) {
      const parsed = parseBashCommand(segment);
      // Match both bare name ("sudo") and absolute path ("/usr/bin/sudo").
      // Extract basename from absolute paths for comparison.
      const execName = parsed.executable.includes("/")
        ? parsed.executable.split("/").pop() || parsed.executable
        : parsed.executable;
      if (execName !== rule.exec) {
        return false;
      }
    }

    if (rule.pattern) {
      // Bash commands are strings, not file paths. minimatch treats '/' as
      // a path separator so '*' won't cross it — 'rm *-*r*' fails to match
      // 'rm -rf /tmp/foo'. Use flat string glob matching.
      if (!matchBashPattern(segment, rule.pattern)) {
        return false;
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
        // evaluate() skips path confinement on bash (covered by exec matching)
        return [];
      default:
        return [];
    }
  }
}
