import {
  chmodSync,
  closeSync,
  existsSync,
  fstatSync,
  mkdirSync,
  openSync,
  readSync,
} from "node:fs";
import { join, resolve } from "node:path";

import { generateId } from "../id.js";
import { createLogger } from "../logger.js";
import { safeErrorMessage } from "../log-utils.js";
import { estimateUsageCostFromModel, normalizePiUsage } from "../token-usage.js";
import type { Session, SessionChangeStats } from "../types.js";
import { openDatabase, type SqliteDatabase, type SqliteStatement } from "../sqlite-compat.js";
import { ConfigStore } from "./config-store.js";
import type {
  WorkspaceSessionSummarySnapshot,
  WorkspaceStoppedTimeBucketSnapshot,
} from "./session-dao.js";
import { loadLegacySessions } from "./session-store.js";

const log = createLogger({ base: { component: "session_sqlite_store" } });
const SCHEMA_VERSION = "5";

interface SessionJsonRow {
  session_json: string;
}

interface SessionProjectionRow {
  id: string;
  workspace_id: string | null;
  workspace_name: string | null;
  name: string | null;
  status: Session["status"];
  created_at: number;
  last_activity: number;
  last_agent_reply_at: number | null;
  current_turn_started_at: number | null;
  model: string | null;
  message_count: number;
  tokens_input: number;
  tokens_output: number;
  tokens_cache_read: number;
  tokens_cache_write: number;
  cost: number;
  change_stats_json: string | null;
  context_tokens: number | null;
  context_window: number | null;
  first_message: string | null;
  last_message: string | null;
  warnings_json: string | null;
  thinking_level: string | null;
  pi_session_file: string | null;
  pi_session_files_json: string | null;
  pi_session_id: string | null;
  ephemeral: number;
  parent_session_id: string | null;
}

interface SessionIdRow {
  id: string;
}

interface WorkspaceSummaryRow {
  workspace_id: string;
  latest_activity: number | null;
  active_count: number;
  stopped_count: number;
  has_error_root: number;
}

interface WorkspaceStoppedTimeBucketRow {
  bucket_kind: "day" | "month";
  bucket_key: string;
  latest_activity: number | null;
  item_count: number;
}

export interface SessionSqliteSyncResult {
  upserted: number;
  deleted: number;
}

export interface SessionSqliteStoreOptions {
  dbPath?: string;
}

export interface SessionSqliteSyncOptions {
  deleteMissing?: boolean;
  force?: boolean;
}

const SESSION_PROJECTION_COLUMNS = `
  id,
  workspace_id,
  workspace_name,
  name,
  status,
  created_at,
  last_activity,
  last_agent_reply_at,
  current_turn_started_at,
  model,
  message_count,
  tokens_input,
  tokens_output,
  tokens_cache_read,
  tokens_cache_write,
  cost,
  change_stats_json,
  context_tokens,
  context_window,
  first_message,
  last_message,
  warnings_json,
  thinking_level,
  pi_session_file,
  pi_session_files_json,
  pi_session_id,
  ephemeral,
  parent_session_id
`;

const SESSION_COLUMN_DEFINITIONS = [
  ["workspace_id", "TEXT"],
  ["workspace_name", "TEXT"],
  ["name", "TEXT"],
  ["status", "TEXT NOT NULL DEFAULT 'stopped'"],
  ["created_at", "INTEGER NOT NULL DEFAULT 0"],
  ["last_activity", "INTEGER NOT NULL DEFAULT 0"],
  ["last_agent_reply_at", "INTEGER"],
  ["current_turn_started_at", "INTEGER"],
  ["model", "TEXT"],
  ["message_count", "INTEGER NOT NULL DEFAULT 0"],
  ["tokens_input", "INTEGER NOT NULL DEFAULT 0"],
  ["tokens_output", "INTEGER NOT NULL DEFAULT 0"],
  ["tokens_cache_read", "INTEGER NOT NULL DEFAULT 0"],
  ["tokens_cache_write", "INTEGER NOT NULL DEFAULT 0"],
  ["cost", "REAL NOT NULL DEFAULT 0"],
  ["change_stats_json", "TEXT"],
  ["context_tokens", "INTEGER"],
  ["context_window", "INTEGER"],
  ["first_message", "TEXT"],
  ["last_message", "TEXT"],
  ["warnings_json", "TEXT"],
  ["thinking_level", "TEXT"],
  ["pi_session_file", "TEXT"],
  ["pi_session_files_json", "TEXT"],
  ["pi_session_id", "TEXT"],
  ["ephemeral", "INTEGER NOT NULL DEFAULT 0"],
  ["parent_session_id", "TEXT"],
  ["session_json", "TEXT NOT NULL DEFAULT ''"],
  ["updated_at", "INTEGER NOT NULL DEFAULT 0"],
] as const;

export class SessionSqliteStore {
  private readonly dbPath: string;
  private readonly db: SqliteDatabase;
  private cache: Map<string, Session> | null = null;

  private stmtUpsert!: SqliteStatement;
  private stmtGet!: SqliteStatement;
  private stmtList!: SqliteStatement;
  private stmtListByWorkspace!: SqliteStatement;
  private stmtListIds!: SqliteStatement;
  private stmtDelete!: SqliteStatement;

  constructor(dataDir: string, dbPathOrOptions?: string | SessionSqliteStoreOptions) {
    if (!existsSync(dataDir)) {
      mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    }

    const options: SessionSqliteStoreOptions =
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
    this.cache = null;
    this.db.close();
  }

  countSessions(): number {
    return (this.stmtListIds.all() as SessionIdRow[]).length;
  }

  createSession(name?: string, model?: string): Session {
    const now = Date.now();
    const session: Session = {
      id: generateId(8),
      name,
      status: "ready",
      createdAt: now,
      lastActivity: now,
      ...(model ? { model } : {}),
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };

    this.saveSession(session);
    return session;
  }

  saveSession(session: Session): void {
    this.upsertSession(session);
  }

  upsertSession(session: Session): void {
    const restored = this.restoreInternalFields(session);
    const normalized = normalizeDeclaredSession(restored);
    const json = JSON.stringify(normalized);

    this.stmtUpsert.run(
      normalized.id,
      normalized.workspaceId ?? null,
      normalized.workspaceName ?? null,
      normalized.name ?? null,
      normalized.status,
      normalized.createdAt,
      normalized.lastActivity,
      normalized.lastAgentReplyAt ?? null,
      normalized.currentTurnStartedAt ?? null,
      normalized.model ?? null,
      normalized.messageCount,
      normalized.tokens.input,
      normalized.tokens.output,
      normalized.tokens.cacheRead,
      normalized.tokens.cacheWrite,
      normalized.cost,
      normalized.changeStats ? JSON.stringify(normalized.changeStats) : null,
      normalized.contextTokens ?? null,
      normalized.contextWindow ?? null,
      normalized.firstMessage ?? null,
      normalized.lastMessage ?? null,
      normalized.warnings ? JSON.stringify(normalized.warnings) : null,
      normalized.thinkingLevel ?? null,
      normalized.piSessionFile ?? null,
      normalized.piSessionFiles ? JSON.stringify(normalized.piSessionFiles) : null,
      normalized.piSessionId ?? null,
      normalized.ephemeral ? 1 : 0,
      normalized.parentSessionId ?? null,
      json,
      Date.now(),
    );
    this.cache?.set(normalized.id, stripInternalFields(normalized));
  }

  getSession(sessionId: string): Session | undefined {
    const cached = this.cache?.get(sessionId);
    if (cached) return cached;

    const session = this.getSessionFromDb(sessionId);
    if (!session) return undefined;

    const stripped = stripInternalFields(session);
    this.cache?.set(session.id, stripped);
    return stripped;
  }

  listSessions(): Session[] {
    return sortSessions(Array.from(this.ensureCache().values()));
  }

  listSessionsByWorkspace(workspaceId: string): Session[] {
    const rows = this.stmtListByWorkspace.all(workspaceId) as SessionJsonRow[];
    return this.parseJsonRows(rows).map(stripInternalFields);
  }

  listSessionsWithoutWorkspace(): Session[] {
    const rows = this.db
      .prepare(
        `SELECT session_json
         FROM session_state_sessions
         WHERE workspace_id IS NULL
         ORDER BY last_activity DESC, id ASC`,
      )
      .all() as SessionJsonRow[];
    return this.parseJsonRows(rows).map(stripInternalFields);
  }

  listAllWorkspaceSessionSnapshots(workspaceId: string): Session[] {
    return this.queryWorkspaceProjectedSessions(workspaceId);
  }

  listRecentWorkspaceSessionSnapshots(
    workspaceId: string,
    recentDays: number,
    nowMs: number = Date.now(),
  ): Session[] {
    const normalizedRecentDays = normalizePositiveInteger(recentDays);
    if (!normalizedRecentDays) {
      return this.queryWorkspaceProjectedSessions(workspaceId);
    }

    return this.queryWorkspaceProjectedSessions(workspaceId, {
      stoppedSinceMs: nowMs - normalizedRecentDays * 86_400_000,
    });
  }

  listWorkspaceTimeRangeSessionSnapshots(
    workspaceId: string,
    sinceMs: number,
    untilMs: number,
  ): Session[] {
    return this.queryWorkspaceProjectedSessions(workspaceId, {
      stoppedSinceMs: normalizeTimestamp(sinceMs),
      stoppedUntilMs: normalizeTimestamp(untilMs),
    });
  }

  listStoppedWorkspaceTimeRangeSessionSnapshots(
    workspaceId: string,
    sinceMs: number,
    untilMs: number,
  ): Session[] {
    return this.queryWorkspaceProjectedSessions(workspaceId, {
      status: "stopped",
      stoppedSinceMs: normalizeTimestamp(sinceMs),
      stoppedUntilMs: normalizeTimestamp(untilMs),
    });
  }

  listWorkspaceSessionSummarySnapshots(): WorkspaceSessionSummarySnapshot[] {
    const rows = this.db
      .prepare(
        `SELECT
           s.workspace_id AS workspace_id,
           MAX(s.last_activity) AS latest_activity,
           SUM(CASE WHEN parent.id IS NULL AND s.status <> 'stopped' THEN 1 ELSE 0 END) AS active_count,
           SUM(CASE WHEN parent.id IS NULL AND s.status = 'stopped' THEN 1 ELSE 0 END) AS stopped_count,
           MAX(CASE WHEN parent.id IS NULL AND s.status = 'error' THEN 1 ELSE 0 END) AS has_error_root
         FROM session_state_sessions s
         LEFT JOIN session_state_sessions parent
           ON parent.id = s.parent_session_id
          AND parent.workspace_id = s.workspace_id
         WHERE s.workspace_id IS NOT NULL
         GROUP BY s.workspace_id
         ORDER BY latest_activity DESC, s.workspace_id ASC`,
      )
      .all() as WorkspaceSummaryRow[];

    return rows.map((row) => ({
      workspaceId: row.workspace_id,
      activeCount: row.active_count,
      stoppedCount: row.stopped_count,
      hasErrorRoot: row.has_error_root > 0,
      ...(row.latest_activity !== null ? { latestActivity: row.latest_activity } : {}),
    }));
  }

  listWorkspaceStoppedTimeBuckets(
    workspaceId: string,
    beforeMs: number,
    nowMs: number = Date.now(),
  ): WorkspaceStoppedTimeBucketSnapshot[] {
    const recentDayCutoffMs = nowMs - 30 * 86_400_000;
    const rows = this.db
      .prepare(
        `SELECT
           CASE WHEN last_activity >= ? THEN 'day' ELSE 'month' END AS bucket_kind,
           CASE
             WHEN last_activity >= ?
               THEN strftime('%Y-%m-%d', last_activity / 1000.0, 'unixepoch', 'localtime')
             ELSE strftime('%Y-%m', last_activity / 1000.0, 'unixepoch', 'localtime')
           END AS bucket_key,
           MAX(last_activity) AS latest_activity,
           COUNT(*) AS item_count
         FROM session_state_sessions
         WHERE workspace_id = ?
           AND status = 'stopped'
           AND last_activity < ?
         GROUP BY bucket_kind, bucket_key
         ORDER BY latest_activity DESC, bucket_key DESC`,
      )
      .all(
        recentDayCutoffMs,
        recentDayCutoffMs,
        workspaceId,
        beforeMs,
      ) as WorkspaceStoppedTimeBucketRow[];

    return rows.flatMap((row) => {
      const range = localBucketRangeMs(row.bucket_kind, row.bucket_key);
      if (!range) {
        return [];
      }
      return [
        {
          bucketId: `${row.bucket_kind}:${row.bucket_key}`,
          bucketKind: row.bucket_kind,
          startMs: range.startMs,
          endMs: range.endMs,
          itemCount: row.item_count,
          ...(row.latest_activity !== null ? { latestActivity: row.latest_activity } : {}),
        },
      ];
    });
  }

  deleteSession(sessionId: string): boolean {
    const existed = this.cache
      ? this.cache.has(sessionId)
      : this.stmtGet.get(sessionId) !== undefined;
    this.stmtDelete.run(sessionId);
    this.cache?.delete(sessionId);

    // Legacy JSON sidecars are import-only now. Keep the file on disk and
    // record a SQLite tombstone so incomplete legacy imports do not resurrect a
    // deleted session on the next boot.
    this.markMigration(legacySessionDeleteMigrationKey(sessionId));

    return existed;
  }

  syncFromSource(
    sessions: Session[],
    options: SessionSqliteSyncOptions = {},
  ): SessionSqliteSyncResult {
    const sourceIds = new Set(sessions.map((session) => session.id));
    let upserted = 0;
    let deleted = 0;

    this.db.transaction(() => {
      for (const session of sessions) {
        const existing = options.force ? undefined : this.getSessionFromDb(session.id);
        if (existing && !shouldImportSourceSession(session, existing)) {
          continue;
        }
        this.upsertSession(session);
        upserted += 1;
      }

      if (options.deleteMissing === true) {
        const rows = this.stmtListIds.all() as SessionIdRow[];
        for (const row of rows) {
          if (sourceIds.has(row.id)) {
            continue;
          }
          this.stmtDelete.run(row.id);
          this.cache?.delete(row.id);
          deleted += 1;
        }
      }
    })();

    return { upserted, deleted };
  }

  private importLegacyJsonOnce(dataDir: string): SessionSqliteSyncResult {
    const migrationKey = "sessions_json_import_sqlite_backend_v2";
    if (this.hasMigration(migrationKey)) {
      return { upserted: 0, deleted: 0 };
    }

    const configStore = new ConfigStore(dataDir);
    const { sessions, failures } = loadLegacySessions(configStore);
    const filteredSessions = sessions.filter(
      (session) => !this.hasMigration(legacySessionDeleteMigrationKey(session.id)),
    );
    const result = this.syncFromSource(filteredSessions);

    if (failures.length > 0) {
      log.warn("session_sqlite_store.legacy_json_import.incomplete", {
        failedFiles: failures.length,
      });
      return result;
    }

    this.markMigration(migrationKey);
    return result;
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

  private ensureSchema(): void {
    const hasSessionTable = this.db
      .prepare(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='session_state_sessions'",
      )
      .get();

    if (!hasSessionTable) {
      this.createCurrentSchema();
      return;
    }

    this.ensureSessionColumns();
    this.ensureSessionIndexesAndSchemaVersion();
    this.backfillMissingSessionJson();
  }

  private createCurrentSchema(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS session_state_sessions (
        id TEXT PRIMARY KEY,
        workspace_id TEXT,
        workspace_name TEXT,
        name TEXT,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        last_activity INTEGER NOT NULL,
        last_agent_reply_at INTEGER,
        current_turn_started_at INTEGER,
        model TEXT,
        message_count INTEGER NOT NULL,
        tokens_input INTEGER NOT NULL,
        tokens_output INTEGER NOT NULL,
        tokens_cache_read INTEGER NOT NULL,
        tokens_cache_write INTEGER NOT NULL,
        cost REAL NOT NULL,
        change_stats_json TEXT,
        context_tokens INTEGER,
        context_window INTEGER,
        first_message TEXT,
        last_message TEXT,
        warnings_json TEXT,
        thinking_level TEXT,
        pi_session_file TEXT,
        pi_session_files_json TEXT,
        pi_session_id TEXT,
        ephemeral INTEGER NOT NULL DEFAULT 0,
        parent_session_id TEXT,
        session_json TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      );
    `);
    this.ensureSessionIndexesAndSchemaVersion();
  }

  private ensureSessionColumns(): void {
    const rows = this.db.prepare("PRAGMA table_info(session_state_sessions)").all() as Array<{
      name: string;
    }>;
    const columns = new Set(rows.map((row) => row.name));
    if (!columns.has("id")) {
      throw new Error("session_state_sessions is missing id; refusing destructive migration");
    }

    for (const [name, definition] of SESSION_COLUMN_DEFINITIONS) {
      if (!columns.has(name)) {
        this.db.exec(`ALTER TABLE session_state_sessions ADD COLUMN ${name} ${definition}`);
      }
    }
  }

  private ensureSessionIndexesAndSchemaVersion(): void {
    this.db.exec(`
      CREATE INDEX IF NOT EXISTS session_state_sessions_workspace_activity_idx
        ON session_state_sessions (workspace_id, last_activity DESC, id ASC);

      CREATE INDEX IF NOT EXISTS session_state_sessions_status_activity_idx
        ON session_state_sessions (status, last_activity DESC, id ASC);

      CREATE INDEX IF NOT EXISTS session_state_sessions_parent_idx
        ON session_state_sessions (parent_session_id);

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

  private backfillMissingSessionJson(): void {
    const rows = this.db
      .prepare(
        `SELECT ${SESSION_PROJECTION_COLUMNS}
         FROM session_state_sessions
         WHERE session_json IS NULL OR session_json = ''`,
      )
      .all() as SessionProjectionRow[];

    if (rows.length === 0) {
      return;
    }

    const update = this.db.prepare(
      "UPDATE session_state_sessions SET session_json = ? WHERE id = ?",
    );
    this.db.transaction(() => {
      for (const row of rows) {
        const session = normalizeDeclaredSession(buildProjectedSession(row));
        update.run(JSON.stringify(session), row.id);
      }
    })();
  }

  private prepareStatements(): void {
    this.stmtUpsert = this.db.prepare(`
      INSERT INTO session_state_sessions (
        id,
        workspace_id,
        workspace_name,
        name,
        status,
        created_at,
        last_activity,
        last_agent_reply_at,
        current_turn_started_at,
        model,
        message_count,
        tokens_input,
        tokens_output,
        tokens_cache_read,
        tokens_cache_write,
        cost,
        change_stats_json,
        context_tokens,
        context_window,
        first_message,
        last_message,
        warnings_json,
        thinking_level,
        pi_session_file,
        pi_session_files_json,
        pi_session_id,
        ephemeral,
        parent_session_id,
        session_json,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        workspace_id = excluded.workspace_id,
        workspace_name = excluded.workspace_name,
        name = excluded.name,
        status = excluded.status,
        created_at = excluded.created_at,
        last_activity = excluded.last_activity,
        last_agent_reply_at = excluded.last_agent_reply_at,
        current_turn_started_at = excluded.current_turn_started_at,
        model = excluded.model,
        message_count = excluded.message_count,
        tokens_input = excluded.tokens_input,
        tokens_output = excluded.tokens_output,
        tokens_cache_read = excluded.tokens_cache_read,
        tokens_cache_write = excluded.tokens_cache_write,
        cost = excluded.cost,
        change_stats_json = excluded.change_stats_json,
        context_tokens = excluded.context_tokens,
        context_window = excluded.context_window,
        first_message = excluded.first_message,
        last_message = excluded.last_message,
        warnings_json = excluded.warnings_json,
        thinking_level = excluded.thinking_level,
        pi_session_file = excluded.pi_session_file,
        pi_session_files_json = excluded.pi_session_files_json,
        pi_session_id = excluded.pi_session_id,
        ephemeral = excluded.ephemeral,
        parent_session_id = excluded.parent_session_id,
        session_json = excluded.session_json,
        updated_at = excluded.updated_at
    `);

    this.stmtGet = this.db.prepare("SELECT session_json FROM session_state_sessions WHERE id = ?");
    this.stmtList = this.db.prepare(`
      SELECT session_json
      FROM session_state_sessions
      ORDER BY last_activity DESC, id ASC
    `);
    this.stmtListByWorkspace = this.db.prepare(`
      SELECT session_json
      FROM session_state_sessions
      WHERE workspace_id = ?
      ORDER BY last_activity DESC, id ASC
    `);
    this.stmtListIds = this.db.prepare("SELECT id FROM session_state_sessions");
    this.stmtDelete = this.db.prepare("DELETE FROM session_state_sessions WHERE id = ?");
  }

  private ensureCache(): Map<string, Session> {
    if (this.cache) {
      return this.cache;
    }

    this.cache = new Map();
    for (const session of this.parseJsonRows(this.stmtList.all() as SessionJsonRow[])) {
      this.cache.set(session.id, stripInternalFields(session));
    }
    return this.cache;
  }

  private parseJsonRows(rows: SessionJsonRow[]): Session[] {
    const sessions: Session[] = [];
    for (const row of rows) {
      const session = this.parseSession(row.session_json);
      if (session) {
        sessions.push(session);
      }
    }
    return sessions;
  }

  private parseProjectedRows(rows: SessionProjectionRow[]): Session[] {
    return rows.map((row) => buildProjectedSession(row));
  }

  private parseSession(rawJson: string, sessionIdForLog?: string): Session | undefined {
    try {
      return normalizeDeclaredSession(JSON.parse(rawJson) as Session);
    } catch (error) {
      log.error("session_sqlite_store.row_parse.failed", {
        sessionId: sessionIdForLog,
        error: safeErrorMessage(error),
      });
      return undefined;
    }
  }

  private getSessionFromDb(sessionId: string): Session | undefined {
    const row = this.stmtGet.get(sessionId) as SessionJsonRow | undefined;
    return row ? this.parseSession(row.session_json, sessionId) : undefined;
  }

  private restoreInternalFields(session: Session): Session {
    if (session.changeStats?._fileLineCounts) return session;
    if (!session.changeStats || session.changeStats.filesChanged === 0) return session;

    const existing = this.getSessionFromDb(session.id);
    if (!existing?.changeStats?._fileLineCounts) return session;

    return {
      ...session,
      changeStats: {
        ...session.changeStats,
        _fileLineCounts: existing.changeStats._fileLineCounts,
        _sessionCreatedFiles: existing.changeStats._sessionCreatedFiles,
      },
    };
  }

  private queryWorkspaceProjectedSessions(
    workspaceId: string,
    filters: {
      status?: Session["status"];
      stoppedSinceMs?: number;
      stoppedUntilMs?: number;
    } = {},
  ): Session[] {
    const whereParts = ["workspace_id = ?"];
    const params: unknown[] = [workspaceId];

    if (filters.status) {
      whereParts.push("status = ?");
      params.push(filters.status);
    }

    if (filters.stoppedSinceMs !== undefined) {
      if (filters.status === "stopped") {
        whereParts.push("last_activity >= ?");
      } else {
        whereParts.push("(status <> 'stopped' OR last_activity >= ?)");
      }
      params.push(filters.stoppedSinceMs);
    }

    if (filters.stoppedUntilMs !== undefined) {
      if (filters.status === "stopped") {
        whereParts.push("last_activity < ?");
      } else {
        whereParts.push("(status <> 'stopped' OR last_activity < ?)");
      }
      params.push(filters.stoppedUntilMs);
    }

    const whereSql = whereParts.join(" AND ");
    const rows = this.db
      .prepare(
        `SELECT ${SESSION_PROJECTION_COLUMNS}
         FROM session_state_sessions
         WHERE ${whereSql}
         ORDER BY last_activity DESC, id ASC`,
      )
      .all(...params) as SessionProjectionRow[];

    return this.includeProjectedAncestors(workspaceId, this.parseProjectedRows(rows));
  }

  private getProjectedSessionById(workspaceId: string, sessionId: string): Session | undefined {
    const row = this.db
      .prepare(
        `SELECT ${SESSION_PROJECTION_COLUMNS}
         FROM session_state_sessions
         WHERE workspace_id = ? AND id = ?`,
      )
      .get(workspaceId, sessionId) as SessionProjectionRow | undefined;
    return row ? buildProjectedSession(row) : undefined;
  }

  private includeProjectedAncestors(workspaceId: string, sessions: Session[]): Session[] {
    const byId = new Map(sessions.map((session) => [session.id, session]));
    const pending = sessions.flatMap((session) =>
      session.parentSessionId ? [session.parentSessionId] : [],
    );
    let remainingLookups = 256;

    while (pending.length > 0 && remainingLookups > 0) {
      remainingLookups -= 1;
      const parentId = pending.pop();
      if (!parentId || byId.has(parentId)) {
        continue;
      }

      const parent = this.getProjectedSessionById(workspaceId, parentId);
      if (!parent) {
        continue;
      }

      byId.set(parent.id, parent);
      if (parent.parentSessionId) {
        pending.push(parent.parentSessionId);
      }
    }

    return sortSessions(Array.from(byId.values()));
  }
}

function buildProjectedSession(row: SessionProjectionRow): Session {
  const session: Session = {
    id: row.id,
    status: row.status,
    createdAt: row.created_at,
    lastActivity: row.last_activity,
    messageCount: row.message_count,
    tokens: {
      input: row.tokens_input,
      output: row.tokens_output,
      cacheRead: row.tokens_cache_read,
      cacheWrite: row.tokens_cache_write,
    },
    cost: row.cost,
  };

  if (row.workspace_id !== null) session.workspaceId = row.workspace_id;
  if (row.workspace_name !== null) session.workspaceName = row.workspace_name;
  if (row.name !== null) session.name = row.name;
  if (row.last_agent_reply_at !== null) session.lastAgentReplyAt = row.last_agent_reply_at;
  if (row.current_turn_started_at !== null)
    session.currentTurnStartedAt = row.current_turn_started_at;
  if (row.model !== null) session.model = row.model;
  if (row.context_tokens !== null) session.contextTokens = row.context_tokens;
  if (row.context_window !== null) session.contextWindow = row.context_window;
  if (row.first_message !== null) session.firstMessage = row.first_message;
  if (row.last_message !== null) session.lastMessage = row.last_message;
  if (row.thinking_level !== null) session.thinkingLevel = row.thinking_level;
  if (row.pi_session_file !== null) session.piSessionFile = row.pi_session_file;
  if (row.pi_session_id !== null) session.piSessionId = row.pi_session_id;
  if (row.ephemeral !== 0) session.ephemeral = true;
  if (row.parent_session_id !== null) session.parentSessionId = row.parent_session_id;

  const changeStats = parseJsonValue<Session["changeStats"]>(
    row.change_stats_json,
    row.id,
    "changeStats",
  );
  if (changeStats) session.changeStats = changeStats;

  const warnings = parseJsonValue<string[]>(row.warnings_json, row.id, "warnings");
  if (warnings && warnings.length > 0) session.warnings = warnings;

  const piSessionFiles = parseJsonValue<string[]>(
    row.pi_session_files_json,
    row.id,
    "piSessionFiles",
  );
  if (piSessionFiles && piSessionFiles.length > 0) session.piSessionFiles = piSessionFiles;

  return session;
}

function parseJsonValue<T>(
  rawJson: string | null,
  sessionId: string,
  field: string,
): T | undefined {
  if (!rawJson) {
    return undefined;
  }

  try {
    return JSON.parse(rawJson) as T;
  } catch (error) {
    log.error("session_sqlite_store.row_json_field_parse.failed", {
      sessionId,
      field,
      error: safeErrorMessage(error),
    });
    return undefined;
  }
}

function shouldImportSourceSession(source: Session, existing: Session): boolean {
  return source.lastActivity > existing.lastActivity;
}

function legacySessionDeleteMigrationKey(sessionId: string): string {
  return `sessions_json_import_sqlite_backend_v2:deleted:${sessionId}`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Backfill cache token fields for sessions persisted before cacheRead/cacheWrite existed. */
function normalizeTokens(tokens: Session["tokens"] | undefined): Session["tokens"] {
  return {
    input: tokens?.input ?? 0,
    output: tokens?.output ?? 0,
    cacheRead: tokens?.cacheRead ?? 0,
    cacheWrite: tokens?.cacheWrite ?? 0,
  };
}

const TRACE_TAIL_INITIAL_BYTES = 256 * 1024;
const TRACE_TAIL_MAX_BYTES = 2 * 1024 * 1024;

function totalTokenUsage(tokens: Session["tokens"]): number {
  return tokens.input + tokens.output + tokens.cacheRead + tokens.cacheWrite;
}

/**
 * Recover the last non-zero context snapshot from the pi JSONL trace.
 *
 * This keeps the existing SessionStore repair behavior while the runtime
 * backing store moves to SQLite. It does not infer or backfill lastAgentReplyAt.
 */
function recoverContextTokensFromTrace(tracePath: string): number | undefined {
  if (!existsSync(tracePath)) {
    return undefined;
  }

  let fd: number | undefined;
  try {
    fd = openSync(tracePath, "r");
    const size = fstatSync(fd).size;
    if (size <= 0) {
      return undefined;
    }

    let bytesToRead = Math.min(size, TRACE_TAIL_INITIAL_BYTES);
    while (bytesToRead > 0) {
      const start = Math.max(0, size - bytesToRead);
      const length = size - start;
      const buffer = Buffer.alloc(length);
      const bytesRead = readSync(fd, buffer, 0, length, start);
      let chunk = buffer.subarray(0, bytesRead).toString("utf8");

      if (start > 0) {
        const firstNewline = chunk.indexOf("\n");
        if (firstNewline === -1) {
          if (bytesToRead >= size || bytesToRead >= TRACE_TAIL_MAX_BYTES) {
            break;
          }
          bytesToRead = Math.min(size, bytesToRead * 2, TRACE_TAIL_MAX_BYTES);
          continue;
        }
        chunk = chunk.slice(firstNewline + 1);
      }

      const lines = chunk.split("\n");
      for (let index = lines.length - 1; index >= 0; index -= 1) {
        const line = lines[index]?.trim();
        if (!line) {
          continue;
        }

        let entry: unknown;
        try {
          entry = JSON.parse(line);
        } catch {
          continue;
        }

        if (!isRecord(entry) || entry.type !== "message") {
          continue;
        }

        const message = isRecord(entry.message) ? entry.message : null;
        if (!message || message.role !== "assistant") {
          continue;
        }

        const usage = normalizePiUsage(message.usage);
        if (!usage) {
          continue;
        }

        const contextTokens = totalTokenUsage(usage);
        if (contextTokens > 0) {
          return contextTokens;
        }
      }

      if (bytesToRead >= size || bytesToRead >= TRACE_TAIL_MAX_BYTES) {
        break;
      }
      bytesToRead = Math.min(size, bytesToRead * 2, TRACE_TAIL_MAX_BYTES);
    }
  } catch {
    return undefined;
  } finally {
    if (fd !== undefined) {
      closeSync(fd);
    }
  }

  return undefined;
}

function backfillContextTokensFromTrace(session: Session): void {
  if ((session.contextTokens ?? 0) > 0) {
    return;
  }

  if (totalTokenUsage(session.tokens) <= 0) {
    return;
  }

  const candidates: string[] = [];
  const pushCandidate = (path: string | undefined): void => {
    if (!path || candidates.includes(path)) {
      return;
    }
    candidates.push(path);
  };

  pushCandidate(session.piSessionFile);
  for (const path of [...(session.piSessionFiles ?? [])].reverse()) {
    pushCandidate(path);
  }

  for (const tracePath of candidates) {
    const recovered = recoverContextTokensFromTrace(tracePath);
    if (recovered && recovered > 0) {
      session.contextTokens = recovered;
      return;
    }
  }
}

function backfillCostFromTokens(session: Session): void {
  if ((session.cost ?? 0) > 0) {
    return;
  }

  if (totalTokenUsage(session.tokens) <= 0) {
    return;
  }

  const recovered = estimateUsageCostFromModel(session.model, session.tokens);
  if (recovered > 0) {
    session.cost = recovered;
  }
}

function normalizePositiveInteger(value: number | undefined): number | undefined {
  if (value === undefined || !Number.isFinite(value)) {
    return undefined;
  }
  const normalized = Math.floor(value);
  return normalized > 0 ? normalized : undefined;
}

function normalizeTimestamp(value: number | undefined): number | undefined {
  if (value === undefined || !Number.isFinite(value)) {
    return undefined;
  }
  return Math.floor(value);
}

function localBucketRangeMs(
  bucketKind: "day" | "month",
  bucketKey: string,
): { startMs: number; endMs: number } | undefined {
  if (bucketKind === "day") {
    const match = bucketKey.match(/^(\d{4})-(\d{2})-(\d{2})$/);
    if (!match) {
      return undefined;
    }
    const [, yearText, monthText, dayText] = match;
    const start = new Date(
      Number.parseInt(yearText, 10),
      Number.parseInt(monthText, 10) - 1,
      Number.parseInt(dayText, 10),
    ).getTime();
    return { startMs: start, endMs: start + 86_400_000 };
  }

  const match = bucketKey.match(/^(\d{4})-(\d{2})$/);
  if (!match) {
    return undefined;
  }
  const [, yearText, monthText] = match;
  const startDate = new Date(Number.parseInt(yearText, 10), Number.parseInt(monthText, 10) - 1, 1);
  const endDate = new Date(Number.parseInt(yearText, 10), Number.parseInt(monthText, 10), 1);
  return { startMs: startDate.getTime(), endMs: endDate.getTime() };
}

function normalizeDeclaredSession(session: Session): Session {
  const normalized: Session = {
    id: session.id,
    status: session.status,
    createdAt: session.createdAt,
    lastActivity: session.lastActivity,
    messageCount: session.messageCount,
    tokens: normalizeTokens(session.tokens),
    cost: session.cost ?? 0,
  };

  if (session.workspaceId !== undefined && session.workspaceId !== null) {
    normalized.workspaceId = session.workspaceId;
  }
  if (session.workspaceName !== undefined && session.workspaceName !== null) {
    normalized.workspaceName = session.workspaceName;
  }
  if (session.name !== undefined && session.name !== null) {
    normalized.name = session.name;
  }
  if (session.lastAgentReplyAt !== undefined && session.lastAgentReplyAt !== null) {
    normalized.lastAgentReplyAt = session.lastAgentReplyAt;
  }
  if (session.currentTurnStartedAt !== undefined && session.currentTurnStartedAt !== null) {
    normalized.currentTurnStartedAt = session.currentTurnStartedAt;
  }
  if (session.model !== undefined && session.model !== null) {
    normalized.model = session.model;
  }
  if (session.changeStats !== undefined && session.changeStats !== null) {
    normalized.changeStats = session.changeStats;
  }
  if (session.contextTokens !== undefined && session.contextTokens !== null) {
    normalized.contextTokens = session.contextTokens;
  }
  if (session.contextWindow !== undefined && session.contextWindow !== null) {
    normalized.contextWindow = session.contextWindow;
  }
  if (session.firstMessage !== undefined && session.firstMessage !== null) {
    normalized.firstMessage = session.firstMessage;
  }
  if (session.lastMessage !== undefined && session.lastMessage !== null) {
    normalized.lastMessage = session.lastMessage;
  }
  if (session.warnings && session.warnings.length > 0) {
    normalized.warnings = [...session.warnings];
  }
  if (session.thinkingLevel !== undefined && session.thinkingLevel !== null) {
    normalized.thinkingLevel = session.thinkingLevel;
  }
  if (session.piSessionFile !== undefined && session.piSessionFile !== null) {
    normalized.piSessionFile = session.piSessionFile;
  }
  if (session.piSessionFiles && session.piSessionFiles.length > 0) {
    normalized.piSessionFiles = [...session.piSessionFiles];
  }
  if (session.piSessionId !== undefined && session.piSessionId !== null) {
    normalized.piSessionId = session.piSessionId;
  }
  if (session.ephemeral === true) {
    normalized.ephemeral = true;
  }
  if (session.parentSessionId !== undefined && session.parentSessionId !== null) {
    normalized.parentSessionId = session.parentSessionId;
  }

  backfillCostFromTokens(normalized);
  backfillContextTokensFromTrace(normalized);

  return normalized;
}

/**
 * Strip internal bookkeeping fields from changeStats before caching.
 * The full data is still written to SQLite in session_json/change_stats_json.
 */
function stripInternalFields(session: Session): Session {
  const stats = session.changeStats;
  if (!stats?._fileLineCounts && !stats?._sessionCreatedFiles) {
    return session;
  }

  const { _fileLineCounts: _, _sessionCreatedFiles: __, ...cleanStats } = stats;
  return { ...session, changeStats: cleanStats as SessionChangeStats };
}

function sortSessions(sessions: Session[]): Session[] {
  return [...sessions].sort((a, b) => {
    if (b.lastActivity !== a.lastActivity) {
      return b.lastActivity - a.lastActivity;
    }
    return a.id.localeCompare(b.id);
  });
}
