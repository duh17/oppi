/**
 * AuditLog — append-only JSONL log of all permission decisions.
 *
 * Storage: ~/.config/oppi/audit.jsonl
 *
 * Every gate decision is recorded: auto-allowed, auto-denied,
 * user-approved, timed out, extension lost. Queryable from the
 * phone for review and debugging.
 */

import { appendFileSync, readFileSync, existsSync, mkdirSync, statSync, renameSync } from "node:fs";
import { dirname } from "node:path";
import { generateId } from "./id.js";


// ─── Types ───

export interface UserChoice {
  action: "allow" | "deny";
  scope: "once" | "session" | "workspace" | "global";
  learnedRuleId?: string;
  expiresAt?: number;
}

export interface AuditEntry {
  id: string;
  timestamp: number;
  sessionId: string;
  workspaceId: string;

  // What was requested
  tool: string;
  displaySummary: string;

  // What happened
  decision: "allow" | "deny";
  resolvedBy: "policy" | "user" | "timeout" | "extension_lost";
  layer: string;
  ruleId?: string;
  ruleSummary?: string;

  // User's choice (if resolvedBy = "user")
  userChoice?: UserChoice;
}

// ─── Constants ───

const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB before rotation
const MAX_QUERY_LIMIT = 500;
const DEFAULT_QUERY_LIMIT = 50;

// ─── AuditLog ───

export class AuditLog {
  private path: string;

  constructor(path: string) {
    this.path = path;
    this.ensureDir();
  }

  /**
   * Record a permission decision.
   */
  record(entry: Omit<AuditEntry, "id" | "timestamp">): AuditEntry {
    const full: AuditEntry = {
      ...entry,
      id: generateId(12),
      timestamp: Date.now(),
    };

    try {
      appendFileSync(this.path, JSON.stringify(full) + "\n", { mode: 0o600 });
    } catch (err) {
      console.error(`[audit] Failed to write: ${err}`);
    }

    // Check rotation
    this.maybeRotate();

    return full;
  }

  /**
   * Query the audit log.
   *
   * Returns entries in reverse chronological order (most recent first).
   * Supports filtering by sessionId and cursor-based pagination.
   */
  query(
    opts: {
      limit?: number;
      before?: number;
      sessionId?: string;
      workspaceId?: string;
    } = {},
  ): AuditEntry[] {
    const limit = Math.min(opts.limit || DEFAULT_QUERY_LIMIT, MAX_QUERY_LIMIT);

    if (!existsSync(this.path)) return [];

    let entries: AuditEntry[];
    try {
      const content = readFileSync(this.path, "utf-8");
      entries = content
        .split("\n")
        .filter((line) => line.trim())
        .map((line) => {
          try {
            return JSON.parse(line) as AuditEntry;
          } catch {
            return null;
          }
        })
        .filter((e): e is AuditEntry => e !== null);
    } catch {
      return [];
    }

    // Filter
    if (opts.workspaceId) {
      entries = entries.filter((e) => e.workspaceId === opts.workspaceId);
    }
    if (opts.sessionId) {
      entries = entries.filter((e) => e.sessionId === opts.sessionId);
    }
    if (opts.before) {
      const before = opts.before;
      entries = entries.filter((e) => e.timestamp < before);
    }

    // Reverse chronological, limited
    entries.reverse();
    return entries.slice(0, limit);
  }

  /**
   * Rotate log file when it exceeds MAX_FILE_SIZE.
   * Renames current to .1 backup (overwrites previous backup).
   */
  maybeRotate(): void {
    try {
      if (!existsSync(this.path)) return;
      const { size } = statSync(this.path);
      if (size < MAX_FILE_SIZE) return;

      const backup = this.path + ".1";
      renameSync(this.path, backup);
      console.log(`[audit] Rotated log (${(size / 1024 / 1024).toFixed(1)}MB) → ${backup}`);
    } catch {
      // Non-critical — rotation failure shouldn't break anything
    }
  }

  private ensureDir(): void {
    const dir = dirname(this.path);
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true, mode: 0o700 });
    }
  }
}
