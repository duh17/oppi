import { randomUUID } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";

import { createLogger } from "../logger.js";
import { safeErrorMessage } from "../log-utils.js";
import { openDatabase, type SqliteDatabase, type SqliteStatement } from "../sqlite-compat.js";
import type {
  AttachReviewCommentsToTurnRequest,
  CreateReviewCommentRequest,
  ReviewComment,
  ReviewCommentAttachment,
  ReviewCommentAuthor,
  ReviewCommentReference,
  ReviewCommentReferenceSource,
  ReviewCommentSeverity,
  ReviewCommentStatus,
  UpdateReviewCommentRequest,
} from "../types.js";
import {
  ReviewCommentStoreError,
  type ReviewCommentDao,
  type ReviewCommentListFilters,
} from "./review-comment-dao.js";

const log = createLogger({ base: { component: "review_comment_sqlite_store" } });
const SCHEMA_VERSION = "4";

const VALID_AUTHORS = new Set<ReviewCommentAuthor>(["human", "agent"]);
const VALID_STATUSES = new Set<ReviewCommentStatus>([
  "staged",
  "sent",
  "open",
  "resolved",
  "dismissed",
]);
const VALID_SEVERITIES = new Set<ReviewCommentSeverity>(["error", "warning", "info"]);
const VALID_SOURCES = new Set<ReviewCommentReferenceSource>([
  "git_diff",
  "file",
  "timeline_text",
  "tool_output",
  "terminal_output",
  "image",
  "unknown",
]);

interface ReviewCommentJsonRow {
  comment_json: string;
}

interface StoredReviewComments {
  version: 1;
  comments: ReviewComment[];
}

export interface ReviewCommentSqliteStoreOptions {
  dbPath?: string;
}

const REVIEW_COMMENT_COLUMN_DEFINITIONS = [
  ["workspace_id", "TEXT NOT NULL DEFAULT ''"],
  ["session_id", "TEXT"],
  ["turn_id", "TEXT"],
  ["author", "TEXT NOT NULL DEFAULT 'human'"],
  ["status", "TEXT NOT NULL DEFAULT 'staged'"],
  ["severity", "TEXT"],
  ["body", "TEXT NOT NULL DEFAULT ''"],
  ["reference_source", "TEXT NOT NULL DEFAULT 'unknown'"],
  ["reference_path", "TEXT"],
  ["reference_timeline_item_id", "TEXT"],
  ["created_at", "INTEGER NOT NULL DEFAULT 0"],
  ["updated_at", "INTEGER NOT NULL DEFAULT 0"],
  ["sent_at", "INTEGER"],
  ["comment_json", "TEXT NOT NULL DEFAULT ''"],
] as const;

export class ReviewCommentSqliteStore implements ReviewCommentDao {
  private readonly dbPath: string;
  private readonly db: SqliteDatabase;
  private readonly legacyImportFailures = new Set<string>();

  private stmtUpsert!: SqliteStatement;
  private stmtGet!: SqliteStatement;
  private stmtDelete!: SqliteStatement;

  constructor(dataDir: string, dbPathOrOptions?: string | ReviewCommentSqliteStoreOptions) {
    if (!existsSync(dataDir)) {
      mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    }

    const options: ReviewCommentSqliteStoreOptions =
      typeof dbPathOrOptions === "string" ? { dbPath: dbPathOrOptions } : (dbPathOrOptions ?? {});

    this.dbPath = resolve(options.dbPath ?? join(dataDir, "session-state.db"));
    this.db = openDatabase(this.dbPath);
    chmodSync(this.dbPath, 0o600);
    this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec("PRAGMA synchronous = NORMAL");
    this.ensureSchema();
    this.prepareStatements();
    this.importLegacyJsonOnce(dataDir);
  }

  getDatabasePath(): string {
    return this.dbPath;
  }

  close(): void {
    this.db.close();
  }

  list(workspaceId: string, filters: ReviewCommentListFilters = {}): ReviewComment[] {
    this.assertLegacyHealthy(workspaceId);

    const whereParts = ["workspace_id = ?"];
    const params: unknown[] = [workspaceId];

    if (filters.sessionId) {
      whereParts.push("session_id = ?");
      params.push(filters.sessionId);
    }

    if (filters.status) {
      whereParts.push("status = ?");
      params.push(filters.status);
    }

    if (filters.path) {
      whereParts.push("reference_path = ?");
      params.push(filters.path);
    }

    const rows = this.db
      .prepare(
        `SELECT comment_json
         FROM review_comments
         WHERE ${whereParts.join(" AND ")}
         ORDER BY created_at ASC, id ASC`,
      )
      .all(...params) as ReviewCommentJsonRow[];

    return rows.map((row) => this.parseComment(row.comment_json));
  }

  create(workspaceId: string, input: CreateReviewCommentRequest): ReviewComment {
    this.assertLegacyHealthy(workspaceId);

    const now = Date.now();
    const comment = normalizeNewReviewComment(workspaceId, input, now);
    this.upsertComment(comment);
    return comment;
  }

  update(workspaceId: string, id: string, patch: UpdateReviewCommentRequest): ReviewComment {
    this.assertLegacyHealthy(workspaceId);

    const current = this.getComment(workspaceId, id);
    if (!current) {
      throw new ReviewCommentStoreError(404, "Review comment not found");
    }

    const updated: ReviewComment = {
      ...current,
      status: patch.status === undefined ? current.status : normalizeStatus(patch.status),
      severity:
        patch.severity === undefined
          ? current.severity
          : patch.severity === null
            ? undefined
            : normalizeSeverity(patch.severity),
      body: patch.body === undefined ? current.body : normalizeBody(patch.body),
      updatedAt: Date.now(),
    };

    this.upsertComment(updated);
    return updated;
  }

  delete(workspaceId: string, id: string): void {
    this.assertLegacyHealthy(workspaceId);

    const existing = this.getComment(workspaceId, id);
    if (!existing) {
      throw new ReviewCommentStoreError(404, "Review comment not found");
    }

    this.stmtDelete.run(workspaceId, id);
  }

  attachToTurn(workspaceId: string, input: AttachReviewCommentsToTurnRequest): ReviewComment[] {
    this.assertLegacyHealthy(workspaceId);

    if (!Array.isArray(input.ids) || input.ids.length === 0) {
      throw new ReviewCommentStoreError(400, "ids array required");
    }

    const ids = new Set(input.ids);
    const transaction = this.db.transaction(() => {
      const existing = this.list(workspaceId).filter((comment) => ids.has(comment.id));
      if (existing.length !== ids.size) {
        throw new ReviewCommentStoreError(404, "One or more review comments were not found");
      }

      const now = Date.now();
      const updated = existing.map((comment) => ({
        ...comment,
        status: "sent" as const,
        sessionId: normalizeOptionalString(input.sessionId) ?? comment.sessionId,
        turnId: normalizeOptionalString(input.turnId) ?? comment.turnId,
        sentAt: now,
        updatedAt: now,
      }));

      for (const comment of updated) {
        this.upsertComment(comment);
      }

      return updated;
    });

    return transaction();
  }

  private getComment(workspaceId: string, id: string): ReviewComment | undefined {
    const row = this.stmtGet.get(workspaceId, id) as ReviewCommentJsonRow | undefined;
    return row ? this.parseComment(row.comment_json) : undefined;
  }

  private upsertComment(comment: ReviewComment): void {
    const normalized = normalizeStoredReviewComment(comment, comment.workspaceId);
    this.stmtUpsert.run(
      normalized.id,
      normalized.workspaceId,
      normalized.sessionId ?? null,
      normalized.turnId ?? null,
      normalized.author,
      normalized.status,
      normalized.severity ?? null,
      normalized.body,
      normalized.reference.source,
      normalized.reference.path ?? null,
      normalized.reference.timelineItemId ?? null,
      normalized.createdAt,
      normalized.updatedAt,
      normalized.sentAt ?? null,
      JSON.stringify(normalized),
    );
  }

  private parseComment(rawJson: string): ReviewComment {
    try {
      return normalizeStoredReviewComment(JSON.parse(rawJson) as unknown);
    } catch (error) {
      log.error("review_comment_sqlite_store.row_parse.failed", {
        error: safeErrorMessage(error),
      });
      throw new ReviewCommentStoreError(500, "Review comment store is corrupted");
    }
  }

  private assertLegacyHealthy(workspaceId: string): void {
    if (this.legacyImportFailures.has(workspaceId)) {
      throw new ReviewCommentStoreError(500, "Review comment store is corrupted");
    }
  }

  private ensureSchema(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS review_comments (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL,
        session_id TEXT,
        turn_id TEXT,
        author TEXT NOT NULL,
        status TEXT NOT NULL,
        severity TEXT,
        body TEXT NOT NULL,
        reference_source TEXT NOT NULL,
        reference_path TEXT,
        reference_timeline_item_id TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        sent_at INTEGER,
        comment_json TEXT NOT NULL
      );
    `);

    this.ensureReviewCommentColumns();
    this.ensureIndexesAndSchemaVersion();
  }

  private ensureReviewCommentColumns(): void {
    const rows = this.db.prepare("PRAGMA table_info(review_comments)").all() as Array<{
      name: string;
    }>;
    const columns = new Set(rows.map((row) => row.name));
    if (!columns.has("id")) {
      throw new Error("review_comments is missing id; refusing destructive migration");
    }

    for (const [name, definition] of REVIEW_COMMENT_COLUMN_DEFINITIONS) {
      if (!columns.has(name)) {
        this.db.exec(`ALTER TABLE review_comments ADD COLUMN ${name} ${definition}`);
      }
    }
  }

  private ensureIndexesAndSchemaVersion(): void {
    this.db.exec(`
      CREATE INDEX IF NOT EXISTS review_comments_workspace_created_idx
        ON review_comments (workspace_id, created_at ASC, id ASC);

      CREATE INDEX IF NOT EXISTS review_comments_workspace_session_idx
        ON review_comments (workspace_id, session_id, created_at ASC, id ASC);

      CREATE INDEX IF NOT EXISTS review_comments_workspace_status_idx
        ON review_comments (workspace_id, status, created_at ASC, id ASC);

      CREATE INDEX IF NOT EXISTS review_comments_workspace_path_idx
        ON review_comments (workspace_id, reference_path, created_at ASC, id ASC);

      CREATE TABLE IF NOT EXISTS session_state_schema (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS app_state_migrations (
        key TEXT PRIMARY KEY,
        completed_at INTEGER NOT NULL
      );

      INSERT OR REPLACE INTO session_state_schema (key, value)
      VALUES ('version', '${SCHEMA_VERSION}');
    `);
  }

  private prepareStatements(): void {
    this.stmtUpsert = this.db.prepare(`
      INSERT INTO review_comments (
        id,
        workspace_id,
        session_id,
        turn_id,
        author,
        status,
        severity,
        body,
        reference_source,
        reference_path,
        reference_timeline_item_id,
        created_at,
        updated_at,
        sent_at,
        comment_json
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        workspace_id = excluded.workspace_id,
        session_id = excluded.session_id,
        turn_id = excluded.turn_id,
        author = excluded.author,
        status = excluded.status,
        severity = excluded.severity,
        body = excluded.body,
        reference_source = excluded.reference_source,
        reference_path = excluded.reference_path,
        reference_timeline_item_id = excluded.reference_timeline_item_id,
        created_at = excluded.created_at,
        updated_at = excluded.updated_at,
        sent_at = excluded.sent_at,
        comment_json = excluded.comment_json
    `);

    this.stmtGet = this.db.prepare(
      "SELECT comment_json FROM review_comments WHERE workspace_id = ? AND id = ?",
    );
    this.stmtDelete = this.db.prepare(
      "DELETE FROM review_comments WHERE workspace_id = ? AND id = ?",
    );
  }

  private importLegacyJsonOnce(dataDir: string): void {
    const migrationKey = "review_comments_json_import_sqlite_backend_v1";
    if (this.hasMigration(migrationKey)) {
      return;
    }

    const legacyDir = join(dataDir, "review-comments");
    if (!existsSync(legacyDir)) {
      this.markMigration(migrationKey);
      return;
    }

    let imported = 0;
    let failures = 0;

    for (const entry of readdirSync(legacyDir, { withFileTypes: true })) {
      if (!entry.isFile() || !entry.name.endsWith(".json")) {
        continue;
      }

      const workspaceId = basename(entry.name, ".json");
      if (!workspaceId) {
        continue;
      }

      try {
        const raw = readFileSync(join(legacyDir, entry.name), "utf8");
        let parsed: unknown;
        try {
          parsed = JSON.parse(raw);
        } catch {
          throw new ReviewCommentStoreError(500, "Review comment store is corrupted");
        }

        if (!isStoredReviewComments(parsed)) {
          throw new ReviewCommentStoreError(500, "Review comment store is corrupted");
        }

        this.db.transaction(() => {
          for (const comment of parsed.comments) {
            this.upsertComment(normalizeStoredReviewComment(comment, workspaceId));
            imported += 1;
          }
        })();
      } catch (error) {
        failures += 1;
        this.legacyImportFailures.add(workspaceId);
        log.warn("review_comment_sqlite_store.legacy_json_import.failed", {
          workspaceId,
          file: entry.name,
          error: safeErrorMessage(error),
        });
      }
    }

    if (failures > 0) {
      log.warn("review_comment_sqlite_store.legacy_json_import.incomplete", {
        importedComments: imported,
        failedFiles: failures,
      });
      return;
    }

    this.markMigration(migrationKey);
  }

  private hasMigration(key: string): boolean {
    return Boolean(this.db.prepare("SELECT key FROM app_state_migrations WHERE key = ?").get(key));
  }

  private markMigration(key: string): void {
    this.db
      .prepare(
        `INSERT INTO app_state_migrations (key, completed_at)
         VALUES (?, ?)
         ON CONFLICT(key) DO UPDATE SET completed_at = excluded.completed_at`,
      )
      .run(key, Date.now());
  }
}

function normalizeNewReviewComment(
  workspaceId: string,
  input: CreateReviewCommentRequest,
  now: number,
): ReviewComment {
  return {
    id: randomUUID(),
    workspaceId,
    sessionId: normalizeOptionalString(input.sessionId),
    author: normalizeAuthor(input.author ?? "human"),
    status: normalizeStatus(input.status ?? "staged"),
    severity: input.severity === undefined ? undefined : normalizeSeverity(input.severity),
    body: normalizeBody(input.body),
    attachments: normalizeAttachments(input.attachments),
    reference: normalizeReference(input.reference),
    createdAt: now,
    updatedAt: now,
  };
}

function normalizeStoredReviewComment(value: unknown, fallbackWorkspaceId?: string): ReviewComment {
  if (!isRecord(value)) {
    throw new ReviewCommentStoreError(500, "Review comment store is corrupted");
  }

  const workspaceId = normalizeOptionalString(value.workspaceId) ?? fallbackWorkspaceId;
  if (!workspaceId) {
    throw new ReviewCommentStoreError(500, "Review comment store is corrupted");
  }

  const comment: ReviewComment = {
    id: normalizeRequiredString(value.id, "id"),
    workspaceId,
    sessionId: normalizeOptionalString(value.sessionId),
    turnId: normalizeOptionalString(value.turnId),
    author: normalizeAuthor(value.author),
    status: normalizeStatus(value.status),
    severity: value.severity === undefined ? undefined : normalizeSeverity(value.severity),
    body: normalizeBody(value.body),
    attachments: normalizeAttachments(value.attachments),
    reference: normalizeReference(value.reference),
    createdAt: normalizeTimestamp(value.createdAt, "createdAt"),
    updatedAt: normalizeTimestamp(value.updatedAt, "updatedAt"),
    sentAt: normalizeOptionalTimestamp(value.sentAt, "sentAt"),
  };

  return dropUndefinedReviewCommentFields(comment);
}

function dropUndefinedReviewCommentFields(comment: ReviewComment): ReviewComment {
  return {
    id: comment.id,
    workspaceId: comment.workspaceId,
    ...(comment.sessionId ? { sessionId: comment.sessionId } : {}),
    ...(comment.turnId ? { turnId: comment.turnId } : {}),
    author: comment.author,
    status: comment.status,
    ...(comment.severity ? { severity: comment.severity } : {}),
    body: comment.body,
    ...(comment.attachments && comment.attachments.length > 0
      ? { attachments: comment.attachments }
      : {}),
    reference: comment.reference,
    createdAt: comment.createdAt,
    updatedAt: comment.updatedAt,
    ...(comment.sentAt !== undefined ? { sentAt: comment.sentAt } : {}),
  };
}

function normalizeBody(value: unknown): string {
  if (typeof value !== "string") {
    throw new ReviewCommentStoreError(400, "body must be a string");
  }
  const normalized = value.trim();
  if (!normalized) {
    throw new ReviewCommentStoreError(400, "body required");
  }
  return normalized;
}

function normalizeAttachments(value: unknown): ReviewComment["attachments"] {
  if (value === undefined) return undefined;
  if (!Array.isArray(value)) {
    throw new ReviewCommentStoreError(400, "attachments must be an array");
  }
  if (value.length === 0) return undefined;
  if (value.length > 8) {
    throw new ReviewCommentStoreError(400, "attachments cannot exceed 8 items");
  }

  return value.map((attachment, index) => normalizeAttachment(attachment, index));
}

function normalizeAttachment(value: unknown, index: number): ReviewCommentAttachment {
  if (!isRecord(value)) {
    throw new ReviewCommentStoreError(400, `attachments[${index}] must be an object`);
  }

  const mimeType = normalizeRequiredString(value.mimeType, `attachments[${index}].mimeType`);
  if (value.kind !== "image") {
    throw new ReviewCommentStoreError(400, `attachments[${index}].kind must be image`);
  }
  if (!mimeType.startsWith("image/")) {
    throw new ReviewCommentStoreError(
      400,
      `attachments[${index}].mimeType must be an image MIME type`,
    );
  }

  return {
    id: normalizeRequiredString(value.id, `attachments[${index}].id`),
    kind: "image",
    mimeType,
    width: normalizeOptionalPositiveInt(value.width, `attachments[${index}].width`),
    height: normalizeOptionalPositiveInt(value.height, `attachments[${index}].height`),
    storageKey: normalizeRequiredString(value.storageKey, `attachments[${index}].storageKey`),
  };
}

function normalizeReference(value: unknown): ReviewCommentReference {
  if (!isRecord(value)) {
    throw new ReviewCommentStoreError(400, "reference object required");
  }
  if (!VALID_SOURCES.has(value.source as ReviewCommentReferenceSource)) {
    throw new ReviewCommentStoreError(400, "reference.source is invalid");
  }

  return {
    source: value.source as ReviewCommentReferenceSource,
    label: normalizeOptionalString(value.label),
    path: normalizeOptionalString(value.path),
    side: normalizeSide(value.side),
    startLine: normalizeOptionalPositiveInt(value.startLine, "reference.startLine"),
    endLine: normalizeOptionalPositiveInt(value.endLine, "reference.endLine"),
    selectedText: normalizeOptionalString(value.selectedText),
    languageHint: normalizeOptionalString(value.languageHint),
    toolCallId: normalizeOptionalString(value.toolCallId),
    timelineItemId: normalizeOptionalString(value.timelineItemId),
    url: normalizeOptionalString(value.url),
  };
}

function normalizeAuthor(value: unknown): ReviewCommentAuthor {
  if (!VALID_AUTHORS.has(value as ReviewCommentAuthor)) {
    throw new ReviewCommentStoreError(400, "author is invalid");
  }
  return value as ReviewCommentAuthor;
}

function normalizeStatus(value: unknown): ReviewCommentStatus {
  if (!VALID_STATUSES.has(value as ReviewCommentStatus)) {
    throw new ReviewCommentStoreError(400, "status is invalid");
  }
  return value as ReviewCommentStatus;
}

function normalizeSeverity(value: unknown): ReviewCommentSeverity {
  if (!VALID_SEVERITIES.has(value as ReviewCommentSeverity)) {
    throw new ReviewCommentStoreError(400, "severity is invalid");
  }
  return value as ReviewCommentSeverity;
}

function normalizeSide(value: unknown): "old" | "new" | "file" | undefined {
  if (value === undefined) return undefined;
  if (value === "old" || value === "new" || value === "file") return value;
  throw new ReviewCommentStoreError(400, "reference.side is invalid");
}

function normalizeOptionalString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const normalized = value.trim();
  return normalized.length > 0 ? normalized : undefined;
}

function normalizeRequiredString(value: unknown, field: string): string {
  const normalized = normalizeOptionalString(value);
  if (!normalized) {
    throw new ReviewCommentStoreError(400, `${field} required`);
  }
  return normalized;
}

function normalizeOptionalPositiveInt(value: unknown, field: string): number | undefined {
  if (value === undefined) return undefined;
  if (!Number.isInteger(value) || (value as number) < 1) {
    throw new ReviewCommentStoreError(400, `${field} must be a positive integer`);
  }
  return value as number;
}

function normalizeTimestamp(value: unknown, field: string): number {
  if (!Number.isFinite(value)) {
    throw new ReviewCommentStoreError(500, `${field} is invalid`);
  }
  return value as number;
}

function normalizeOptionalTimestamp(value: unknown, field: string): number | undefined {
  if (value === undefined) return undefined;
  return normalizeTimestamp(value, field);
}

function isStoredReviewComments(value: unknown): value is StoredReviewComments {
  return (
    typeof value === "object" &&
    value !== null &&
    "comments" in value &&
    Array.isArray((value as { comments?: unknown }).comments)
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
