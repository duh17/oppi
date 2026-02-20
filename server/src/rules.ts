/**
 * RuleStore — persistent learned + manual policy rules.
 *
 * Storage:
 *   ~/.config/oppi/rules.json  — global + workspace rules (persisted)
 *   In-memory only                  — session-scoped rules (ephemeral)
 *
 * Rules are evaluated by PolicyEngine.evaluateWithRules().
 * Created by GateServer when user approves with scope != "once".
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { generateId } from "./id.js";


// ─── Types ───

export interface RuleMatch {
  executable?: string; // "git", "npm", "python3"
  domain?: string; // "github.com" (browser nav)
  pathPattern?: string; // "/workspace/**" (file ops)
  commandPattern?: string; // "git push *" (glob against full command)
}

export interface LearnedRule {
  id: string;
  effect: "allow" | "deny";

  // What to match (all non-null fields must match)
  tool?: string; // "bash", "write", "edit", "*"
  match?: RuleMatch;

  // Scope
  scope: "session" | "workspace" | "global";
  workspaceId?: string; // Required for workspace scope
  sessionId?: string; // Required for session scope

  // Metadata
  source: "learned" | "manual";
  description: string;
  createdAt: number;
  createdBy?: string; // userId who created/approved
  expiresAt?: number; // Optional TTL (ms since epoch)
}

// ─── RuleStore ───

export class RuleStore {
  private path: string;
  private persisted: LearnedRule[] = []; // global + workspace (on disk)
  private sessionRules: LearnedRule[] = []; // session-scoped (in-memory only)

  constructor(path: string) {
    this.path = path;
    this.load();
  }

  // ── CRUD ──

  add(input: Omit<LearnedRule, "id" | "createdAt">): LearnedRule {
    const rule: LearnedRule = {
      ...input,
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
    // Try session rules first
    const sessionIdx = this.sessionRules.findIndex((r) => r.id === id);
    if (sessionIdx >= 0) {
      this.sessionRules.splice(sessionIdx, 1);
      return true;
    }

    // Then persisted
    const idx = this.persisted.findIndex((r) => r.id === id);
    if (idx >= 0) {
      this.persisted.splice(idx, 1);
      this.save();
      return true;
    }

    return false;
  }

  update(
    id: string,
    updates: {
      effect?: LearnedRule["effect"];
      tool?: LearnedRule["tool"] | null;
      match?: LearnedRule["match"];
      description?: string;
      expiresAt?: number | null;
    },
  ): LearnedRule | null {
    const applyUpdates = (rule: LearnedRule): LearnedRule => {
      const next: LearnedRule = { ...rule };

      if (updates.effect !== undefined) {
        next.effect = updates.effect;
      }
      if (updates.description !== undefined) {
        next.description = updates.description;
      }
      if (updates.match !== undefined) {
        next.match = updates.match;
      }
      if (updates.tool !== undefined) {
        if (updates.tool === null) {
          delete next.tool;
        } else {
          next.tool = updates.tool;
        }
      }
      if (updates.expiresAt !== undefined) {
        if (updates.expiresAt === null) {
          delete next.expiresAt;
        } else {
          next.expiresAt = updates.expiresAt;
        }
      }

      return next;
    };

    const sessionIdx = this.sessionRules.findIndex((r) => r.id === id);
    if (sessionIdx >= 0) {
      const updated = applyUpdates(this.sessionRules[sessionIdx]);
      this.sessionRules[sessionIdx] = updated;
      return updated;
    }

    const persistedIdx = this.persisted.findIndex((r) => r.id === id);
    if (persistedIdx >= 0) {
      const updated = applyUpdates(this.persisted[persistedIdx]);
      this.persisted[persistedIdx] = updated;
      this.save();
      return updated;
    }

    return null;
  }

  // ── Queries ──

  /** All rules (persisted + session). */
  getAll(): LearnedRule[] {
    return [...this.persisted, ...this.sessionRules];
  }

  /** Global rules only. */
  getGlobal(): LearnedRule[] {
    return this.persisted.filter((r) => r.scope === "global");
  }

  /** Rules for a specific workspace (includes global rules). */
  getForWorkspace(workspaceId: string): LearnedRule[] {
    return this.persisted.filter(
      (r) => r.scope === "global" || (r.scope === "workspace" && r.workspaceId === workspaceId),
    );
  }

  /** Rules for a specific session (session-scoped only). */
  getForSession(sessionId: string): LearnedRule[] {
    return this.sessionRules.filter((r) => r.sessionId === sessionId);
  }

  /**
   * Find rules that match a given request in a specific context.
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
  ): LearnedRule[] {
    const now = Date.now();
    const candidates = [...this.getForSession(sessionId), ...this.getForWorkspace(workspaceId)];

    return candidates.filter((rule) => {
      // Skip expired
      if (rule.expiresAt && rule.expiresAt < now) return false;

      // Tool must match (or rule.tool is "*")
      if (rule.tool && rule.tool !== "*" && rule.tool !== tool) return false;

      // Match conditions — ALL non-null fields must match
      if (rule.match) {
        if (rule.match.executable && parsed?.executable !== rule.match.executable) return false;
        if (rule.match.domain && parsed?.domain !== rule.match.domain) return false;

        if (rule.match.pathPattern && parsed?.path) {
          // Simple glob: "/workspace/**" matches "/workspace/src/foo.ts"
          const pattern = rule.match.pathPattern;
          if (pattern.endsWith("/**")) {
            const prefix = pattern.slice(0, -3);
            if (!parsed.path.startsWith(prefix)) return false;
          } else if (pattern !== parsed.path) {
            return false;
          }
        } else if (rule.match.pathPattern && !parsed?.path) {
          return false; // Rule requires path but request has none
        }

        if (rule.match.commandPattern) {
          const command = (input as { command?: string }).command || "";
          // Simple glob matching: "git *" matches "git push origin main"
          const re = new RegExp("^" + rule.match.commandPattern.replace(/\*/g, ".*") + "$");
          if (!re.test(command)) return false;
        }
      }

      return true;
    });
  }

  // ── Session lifecycle ──

  /** Remove all session-scoped rules for a session. */
  clearSessionRules(sessionId: string): void {
    this.sessionRules = this.sessionRules.filter((r) => r.sessionId !== sessionId);
  }

  // ── Persistence ──

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
      const data = JSON.parse(content);
      if (Array.isArray(data)) {
        this.persisted = data;
      } else {
        this.persisted = [];
      }
    } catch {
      // Corrupted file — start fresh, don't crash
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
  }
}
