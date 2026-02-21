/**
 * RuleStore — unified policy rule storage.
 *
 * Storage:
 *   ~/.config/oppi/rules.json       global + workspace rules (persisted)
 *   in-memory only                  session-scoped rules (ephemeral)
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, statSync } from "node:fs";
import { dirname, normalize, resolve } from "node:path";
import { homedir } from "node:os";
import { generateId } from "./id.js";

export type RuleDecision = "allow" | "ask" | "deny";
export type RuleScope = "session" | "workspace" | "global";
export type RuleSource = "preset" | "learned" | "manual";

export interface Rule {
  id: string;
  tool: string;
  decision: RuleDecision;
  pattern?: string;
  executable?: string;
  label?: string;

  scope: RuleScope;
  sessionId?: string;
  workspaceId?: string;
  expiresAt?: number;
  source?: RuleSource;
  createdAt: number;
}

export interface RuleInput {
  tool?: string;
  decision?: RuleDecision;
  pattern?: string;
  executable?: string;
  label?: string;
  scope?: RuleScope;
  sessionId?: string;
  workspaceId?: string;
  expiresAt?: number;
  source?: RuleSource;
}

export interface RulePatch {
  tool?: string | null;
  decision?: RuleDecision;
  pattern?: string | null;
  executable?: string | null;
  label?: string | null;
  expiresAt?: number | null;
}

const FILE_TOOLS = new Set(["read", "write", "edit", "find", "ls"]);

function firstGlobIndex(value: string): number {
  for (let i = 0; i < value.length; i++) {
    if (value[i] === "*" || value[i] === "?" || value[i] === "[" || value[i] === "{") {
      return i;
    }
  }
  return -1;
}

function expandHome(value: string): string {
  return value.replace(/^~(?=$|\/)/, homedir());
}

function normalizePathPattern(pattern: string): string {
  const expanded = expandHome(pattern.trim());
  const idx = firstGlobIndex(expanded);

  if (idx === -1) {
    return normalize(resolve(expanded));
  }

  const prefix = expanded.slice(0, idx);
  const suffix = expanded.slice(idx);

  if (!prefix) return expanded;

  const normalizedPrefix = normalize(resolve(prefix));
  const needsSlash = prefix.endsWith("/") && !normalizedPrefix.endsWith("/");
  return `${normalizedPrefix}${needsSlash ? "/" : ""}${suffix}`;
}

interface NormalizedRuleInput {
  tool: string;
  decision: RuleDecision;
  pattern?: string;
  executable?: string;
  label?: string;
  scope: RuleScope;
  sessionId?: string;
  workspaceId?: string;
  expiresAt?: number;
  source?: RuleSource;
}

function normalizeRuleInput(input: RuleInput): NormalizedRuleInput {
  const decision = parseDecision(input.decision) || "allow";
  const scope: RuleScope =
    input.scope === "session" || input.scope === "workspace" || input.scope === "global"
      ? input.scope
      : "global";

  const tool =
    typeof input.tool === "string" && input.tool.trim().length > 0 ? input.tool.trim() : "*";

  const normalized: NormalizedRuleInput = {
    tool,
    decision,
    scope,
    sessionId: typeof input.sessionId === "string" ? input.sessionId : undefined,
    workspaceId: typeof input.workspaceId === "string" ? input.workspaceId : undefined,
    expiresAt: typeof input.expiresAt === "number" ? input.expiresAt : undefined,
    source: input.source,
  };

  if (typeof input.executable === "string" && input.executable.trim().length > 0) {
    normalized.executable = input.executable.trim();
  }

  if (typeof input.label === "string" && input.label.trim().length > 0) {
    normalized.label = input.label.trim();
  }

  if (typeof input.pattern === "string" && input.pattern.trim().length > 0) {
    const trimmed = input.pattern.trim();
    normalized.pattern = FILE_TOOLS.has(tool) ? normalizePathPattern(trimmed) : trimmed;
  }

  return normalized;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseDecision(value: unknown): RuleDecision | null {
  if (value === "allow" || value === "ask" || value === "deny") return value;
  if (value === "block") return "deny";
  return null;
}

/** Parse a rule from disk using the current on-disk rule shape. */
function parseRuleFromDisk(raw: unknown): Rule | null {
  if (!isRecord(raw)) return null;
  if (typeof raw.id !== "string") return null;

  const input: RuleInput = {};

  if (typeof raw.tool === "string") input.tool = raw.tool;
  if (typeof raw.decision === "string") input.decision = parseDecision(raw.decision) ?? undefined;
  if (typeof raw.label === "string") input.label = raw.label;
  if (typeof raw.executable === "string") input.executable = raw.executable;
  if (typeof raw.pattern === "string") input.pattern = raw.pattern;

  if (typeof raw.scope === "string") input.scope = raw.scope as RuleScope;
  if (typeof raw.sessionId === "string") input.sessionId = raw.sessionId;
  if (typeof raw.workspaceId === "string") input.workspaceId = raw.workspaceId;
  if (typeof raw.expiresAt === "number") input.expiresAt = raw.expiresAt;
  if (typeof raw.source === "string") input.source = raw.source as RuleSource;

  const normalized = normalizeRuleInput(input);

  return {
    id: raw.id,
    ...normalized,
    createdAt: typeof raw.createdAt === "number" ? raw.createdAt : Date.now(),
  };
}

function ruleSignature(rule: NormalizedRuleInput): string {
  return JSON.stringify({
    tool: rule.tool,
    decision: rule.decision,
    pattern: rule.pattern || "",
    executable: rule.executable || "",
    label: rule.label || "",
    scope: rule.scope,
    sessionId: rule.sessionId || "",
    workspaceId: rule.workspaceId || "",
    source: rule.source || "",
    expiresAt: rule.expiresAt || 0,
  });
}

function ruleConflictKey(rule: {
  tool: string;
  scope: RuleScope;
  pattern?: string;
  executable?: string;
  sessionId?: string;
  workspaceId?: string;
}): string {
  return JSON.stringify({
    tool: rule.tool,
    scope: rule.scope,
    pattern: rule.pattern || "",
    executable: rule.executable || "",
    sessionId: rule.sessionId || "",
    workspaceId: rule.workspaceId || "",
  });
}

function normalizedFromRule(rule: Rule): NormalizedRuleInput {
  return normalizeRuleInput({
    tool: rule.tool,
    decision: rule.decision,
    pattern: rule.pattern,
    executable: rule.executable,
    label: rule.label,
    scope: rule.scope,
    sessionId: rule.sessionId,
    workspaceId: rule.workspaceId,
    expiresAt: rule.expiresAt,
    source: rule.source,
  });
}

export class RuleStore {
  private path: string;
  private persisted: Rule[] = [];
  private sessionRules: Rule[] = [];
  private _lastMtimeMs = 0;

  constructor(path: string) {
    this.path = path;
    this.load();
    this._lastMtimeMs = this.fileMtime();
  }

  seedIfEmpty(seedRules: RuleInput[]): void {
    const signatures = new Set(
      this.persisted.map((rule) =>
        ruleSignature(
          normalizeRuleInput({
            tool: rule.tool,
            decision: rule.decision,
            pattern: rule.pattern,
            executable: rule.executable,
            label: rule.label,
            scope: rule.scope,
            sessionId: rule.sessionId,
            workspaceId: rule.workspaceId,
            expiresAt: rule.expiresAt,
            source: rule.source,
          }),
        ),
      ),
    );

    let added = 0;

    for (const input of seedRules) {
      const normalized = normalizeRuleInput(input);
      const signature = ruleSignature(normalized);
      if (signatures.has(signature)) continue;

      try {
        this.assertNoConflictingDecision(normalized);
      } catch {
        // Existing user/manual decision wins over seed defaults.
        continue;
      }

      this.persisted.push({
        ...normalized,
        id: generateId(12),
        createdAt: Date.now(),
      });
      signatures.add(signature);
      added += 1;
    }

    if (added > 0) {
      this.save();
    }
  }

  ensureWorkspaceDefaults(workspaceId: string, workspaceRoot: string): Rule[] {
    const base = normalize(resolve(expandHome(workspaceRoot)));
    const pattern = `${base}/**`;

    const seeds: RuleInput[] = [
      {
        tool: "read",
        decision: "allow",
        pattern,
        scope: "workspace",
        workspaceId,
        source: "preset",
        label: "Workspace read access",
      },
      {
        tool: "write",
        decision: "allow",
        pattern,
        scope: "workspace",
        workspaceId,
        source: "preset",
        label: "Workspace write access",
      },
      {
        tool: "edit",
        decision: "allow",
        pattern,
        scope: "workspace",
        workspaceId,
        source: "preset",
        label: "Workspace edit access",
      },
    ];

    const added: Rule[] = [];

    for (const seed of seeds) {
      const normalized = normalizeRuleInput(seed);
      const exists = this.persisted.some(
        (rule) =>
          rule.scope === normalized.scope &&
          rule.workspaceId === normalized.workspaceId &&
          rule.tool === normalized.tool &&
          rule.pattern === normalized.pattern &&
          rule.decision === normalized.decision,
      );

      if (exists) continue;

      try {
        this.assertNoConflictingDecision(normalized);
      } catch {
        // Keep explicit user decisions; skip conflicting workspace seeds.
        continue;
      }

      const created: Rule = {
        ...normalized,
        id: generateId(12),
        createdAt: Date.now(),
      };

      this.persisted.push(created);
      added.push(created);
    }

    if (added.length > 0) {
      this.save();
    }

    return added;
  }

  add(input: RuleInput): Rule {
    const normalized = normalizeRuleInput(input);

    if (normalized.scope === "session" && !normalized.sessionId) {
      throw new Error("sessionId is required for session-scoped rules");
    }
    if (normalized.scope === "workspace" && !normalized.workspaceId) {
      throw new Error("workspaceId is required for workspace-scoped rules");
    }

    this.assertNoConflictingDecision(normalized);

    const duplicate = this.findDuplicate(normalized);
    if (duplicate) {
      return duplicate;
    }

    const rule: Rule = {
      ...normalized,
      id: generateId(12),
      createdAt: Date.now(),
    };

    if (rule.scope === "session") {
      this.sessionRules.push(rule);
    } else {
      this.persisted.push(rule);
      this.save();
    }

    return rule;
  }

  remove(id: string): boolean {
    const sessionIdx = this.sessionRules.findIndex((r) => r.id === id);
    if (sessionIdx >= 0) {
      this.sessionRules.splice(sessionIdx, 1);
      return true;
    }

    const idx = this.persisted.findIndex((r) => r.id === id);
    if (idx >= 0) {
      this.persisted.splice(idx, 1);
      this.save();
      return true;
    }

    return false;
  }

  update(id: string, patch: RulePatch): Rule | null {
    const applyPatch = (rule: Rule): Rule => {
      const next: Rule = { ...rule };

      const patchedDecision = parseDecision(patch.decision);
      if (patchedDecision) next.decision = patchedDecision;

      if (patch.tool !== undefined) {
        if (patch.tool === null) next.tool = "*";
        else next.tool = patch.tool.trim();
      }

      if (patch.pattern !== undefined) {
        if (patch.pattern === null || patch.pattern.trim().length === 0) {
          delete next.pattern;
        } else {
          next.pattern = patch.pattern.trim();
        }
      }

      if (patch.executable !== undefined) {
        if (patch.executable === null || patch.executable.trim().length === 0) {
          delete next.executable;
        } else {
          next.executable = patch.executable.trim();
        }
      }

      if (patch.label !== undefined) {
        if (patch.label === null || patch.label.trim().length === 0) {
          delete next.label;
        } else {
          next.label = patch.label.trim();
        }
      }

      if (patch.expiresAt !== undefined) {
        if (patch.expiresAt === null) delete next.expiresAt;
        else next.expiresAt = patch.expiresAt;
      }

      const normalized = normalizeRuleInput({
        tool: next.tool,
        decision: next.decision,
        pattern: next.pattern,
        executable: next.executable,
        label: next.label,
        scope: next.scope,
        sessionId: next.sessionId,
        workspaceId: next.workspaceId,
        expiresAt: next.expiresAt,
        source: next.source,
      });

      return {
        ...next,
        ...normalized,
      };
    };

    const sessionIdx = this.sessionRules.findIndex((r) => r.id === id);
    if (sessionIdx >= 0) {
      const updated = applyPatch(this.sessionRules[sessionIdx]);
      this.assertNoConflictingDecision(normalizedFromRule(updated), id);
      this.sessionRules[sessionIdx] = updated;
      return updated;
    }

    const persistedIdx = this.persisted.findIndex((r) => r.id === id);
    if (persistedIdx >= 0) {
      const updated = applyPatch(this.persisted[persistedIdx]);
      this.assertNoConflictingDecision(normalizedFromRule(updated), id);
      this.persisted[persistedIdx] = updated;
      this.save();
      return updated;
    }

    return null;
  }

  getAll(): Rule[] {
    this.reloadIfChanged();
    return [...this.persisted, ...this.sessionRules];
  }

  getGlobal(): Rule[] {
    this.reloadIfChanged();
    return this.persisted.filter((r) => r.scope === "global");
  }

  getForWorkspace(workspaceId: string): Rule[] {
    this.reloadIfChanged();
    return this.persisted.filter(
      (r) => r.scope === "global" || (r.scope === "workspace" && r.workspaceId === workspaceId),
    );
  }

  getForSession(sessionId: string): Rule[] {
    return this.sessionRules.filter((r) => r.sessionId === sessionId);
  }

  /**
   * Find rules that match a given request context.
   *
   * Returns matching rules from all applicable scopes:
   *   1. Session rules for this session
   *   2. Workspace rules for this workspace + global rules
   *
   * Caller (PolicyEngine) handles evaluation order and deny-wins logic.
   */
  findMatching(
    tool: string,
    input: Record<string, unknown>,
    sessionId: string,
    workspaceId: string,
    parsed?: { executable?: string; domain?: string; path?: string },
  ): Rule[] {
    const now = Date.now();
    const candidates = [
      ...this.sessionRules.filter((r) => r.scope === "session" && r.sessionId === sessionId),
      ...this.persisted.filter(
        (r) => r.scope === "global" || (r.scope === "workspace" && r.workspaceId === workspaceId),
      ),
    ];

    const command = (input as { command?: string }).command || "";

    return candidates.filter((rule) => {
      if (rule.expiresAt && rule.expiresAt < now) return false;
      if (rule.tool !== "*" && rule.tool !== tool) return false;

      if (rule.executable) {
        if (parsed?.executable !== rule.executable) return false;
      }

      if (rule.pattern) {
        if (tool === "bash") {
          const re = new RegExp("^" + rule.pattern.replace(/\*/g, ".*") + "$");
          if (!re.test(command)) return false;
        } else if (parsed?.path) {
          if (rule.pattern.endsWith("/**")) {
            const prefix = rule.pattern.slice(0, -3);
            if (!parsed.path.startsWith(prefix)) return false;
          } else if (rule.pattern !== parsed.path) {
            return false;
          }
        } else {
          return false;
        }
      }

      return true;
    });
  }

  clearSessionRules(sessionId: string): void {
    this.sessionRules = this.sessionRules.filter((r) => r.sessionId !== sessionId);
  }

  private scopeBucket(scope: RuleScope): Rule[] {
    return scope === "session" ? this.sessionRules : this.persisted;
  }

  private findDuplicate(normalized: NormalizedRuleInput): Rule | null {
    const signature = ruleSignature(normalized);
    const bucket = this.scopeBucket(normalized.scope);

    for (const rule of bucket) {
      if (ruleSignature(normalizedFromRule(rule)) === signature) {
        return rule;
      }
    }

    return null;
  }

  private assertNoConflictingDecision(
    normalized: NormalizedRuleInput,
    excludeRuleId?: string,
  ): void {
    const key = ruleConflictKey(normalized);
    const bucket = this.scopeBucket(normalized.scope);

    for (const rule of bucket) {
      if (excludeRuleId && rule.id === excludeRuleId) continue;

      if (ruleConflictKey(rule) !== key) continue;
      if (rule.decision === normalized.decision) continue;

      throw new Error(
        `Conflicting decision for ${normalized.tool} rule (${normalized.scope} scope): existing ${rule.decision}, requested ${normalized.decision}`,
      );
    }
  }

  /** Get file mtime in ms, or 0 if missing. */
  private fileMtime(): number {
    try {
      return statSync(this.path).mtimeMs;
    } catch {
      return 0;
    }
  }

  /** Re-read rules.json if it was modified externally (e.g. manual edit). */
  private reloadIfChanged(): void {
    const mtime = this.fileMtime();
    if (mtime !== this._lastMtimeMs) {
      this.load();
      this._lastMtimeMs = mtime;
    }
  }

  private load(): void {
    if (!existsSync(this.path)) {
      this.persisted = [];
      return;
    }

    try {
      const content = readFileSync(this.path, "utf-8").trim();
      if (!content) {
        this.persisted = [];
        return;
      }

      const parsed = JSON.parse(content);
      if (!Array.isArray(parsed)) {
        this.persisted = [];
        return;
      }

      const seen = new Set<string>();
      const next: Rule[] = [];

      for (const entry of parsed) {
        const rule = parseRuleFromDisk(entry);
        if (!rule) continue;

        const normalizedInput = normalizeRuleInput({
          tool: rule.tool,
          decision: rule.decision,
          pattern: rule.pattern,
          executable: rule.executable,
          label: rule.label,
          scope: rule.scope,
          sessionId: rule.sessionId,
          workspaceId: rule.workspaceId,
          expiresAt: rule.expiresAt,
          source: rule.source,
        });

        const signature = ruleSignature(normalizedInput);
        if (seen.has(signature)) continue;
        seen.add(signature);

        next.push({
          ...rule,
          ...normalizedInput,
        });
      }

      this.persisted = next;
    } catch {
      console.warn(`[rules] Failed to load ${this.path}, starting fresh`);
      this.persisted = [];
    }
  }

  private save(): void {
    const dir = dirname(this.path);
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true, mode: 0o700 });
    }
    writeFileSync(this.path, JSON.stringify(this.persisted, null, 2), { mode: 0o600 });
    this._lastMtimeMs = this.fileMtime();
  }
}
