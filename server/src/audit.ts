/**
 * AuditLog — append-only JSONL log of all permission decisions.
 *
 * Storage: ~/.config/oppi/audit.jsonl
 *
 * Every gate decision is recorded: policy-allowed, auto-reviewed,
 * user-approved/user-denied, timed out, extension lost. Queryable from the
 * phone for review and debugging.
 */

import { appendFileSync, readFileSync, existsSync, mkdirSync, statSync, renameSync } from "node:fs";
import { dirname } from "node:path";
import { generateId } from "./id.js";
import { createLogger } from "./logger.js";

// ─── Types ───

export interface UserChoice {
  action: "allow" | "deny";
  scope: "once" | "session" | "global";
  learnedRuleId?: string;
  expiresAt?: number;
}

export interface AutoReviewAuditDetails {
  outcome: "allow" | "ask";
  status: string;
  reason: string;
  model?: string;
  riskLevel?: string;
  confidence?: number;
  durationMs?: number;
  tokens?: number;
  promptHash?: string;
}

export interface AuditEntry {
  id: string;
  timestamp: number;
  sessionId: string;
  workspaceId: string;

  // What was requested
  tool: string;
  displaySummary: string;
  /** Permission request id when this decision came from a pending approval flow. */
  requestId?: string;
  /** Tool call id for correlating auto-allowed decisions without a pending request. */
  toolCallId?: string;

  // What happened
  decision: "allow" | "ask" | "deny";
  resolvedBy: "policy" | "auto_review" | "user" | "timeout" | "extension_lost";
  layer: string;
  ruleId?: string;
  ruleSummary?: string;

  // Model review details (if an Auto policy was evaluated)
  autoReview?: AutoReviewAuditDetails;

  // User's choice (if resolvedBy = "user")
  userChoice?: UserChoice;
}

// ─── Constants ───

const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB before rotation
const MAX_QUERY_LIMIT = 500;
const DEFAULT_QUERY_LIMIT = 50;

const log = createLogger({ base: { component: "audit" } });

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
      log.error("audit.write.failed", {
        path: this.path,
        error: String(err),
      });
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

    let lines: string[];
    try {
      const content = readFileSync(this.path, "utf-8");
      lines = content.split("\n");
    } catch {
      return [];
    }

    // The file is append-only chronological. Walk from the tail so recent
    // queries avoid parsing the whole rotated log in the common case.
    const results: AuditEntry[] = [];
    for (let i = lines.length - 1; i >= 0; i -= 1) {
      const line = lines[i]?.trim();
      if (!line) continue;

      let entry: AuditEntry;
      try {
        entry = JSON.parse(line) as AuditEntry;
      } catch {
        continue;
      }

      if (opts.workspaceId && entry.workspaceId !== opts.workspaceId) continue;
      if (opts.sessionId && entry.sessionId !== opts.sessionId) continue;
      if (opts.before && entry.timestamp >= opts.before) continue;

      results.push(entry);
      if (results.length >= limit) break;
    }

    return results;
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
      log.info("audit.rotated", {
        path: this.path,
        sizeMb: (size / 1024 / 1024).toFixed(1),
        backup,
      });
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
