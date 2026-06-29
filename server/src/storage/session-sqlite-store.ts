import { chmodSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";

import { generateId } from "../id.js";
import { createLogger } from "../logger.js";
import { safeErrorMessage } from "../log-utils.js";
import type { Session, SessionChangeStats } from "../types.js";
import { openDatabase, type SqliteDatabase, type SqliteStatement } from "../sqlite-compat.js";
import { ConfigStore } from "./config-store.js";
import type {
  WorkspaceSessionSummarySnapshot,
  WorkspaceStoppedTimeBucketSnapshot,
} from "./session-dao.js";
import { loadLegacySessions } from "./session-store.js";
import {
  backfillContextTokensFromTrace,
  backfillCostFromTokens,
  normalizeSessionTokens,
} from "./session-repair.js";

const log = createLogger({ base: { component: "session_sqlite_store" } });
const SCHEMA_VERSION = "8";

interface SessionJsonRow {
  session_json: string;
}

interface SessionProjectionRow {
  id: string;
  workspace_id: string | null;
  workspace_name: string | null;
  worktree_id: string | null;
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
  runtime: Session["runtime"] | null;
  mirror_json: string | null;
  pi_session_file: string | null;
  pi_session_files_json: string | null;
  pi_session_id: string | null;
  ephemeral: number;
  launch_idempotency_key: string | null;
  launch_source: string | null;
  launch_status: string | null;
  launch_lease_owner: string | null;
  launch_lease_until_ms: number | null;
  launch_metadata_json: string | null;
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
  worktree_id,
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
  runtime,
  mirror_json,
  pi_session_file,
  pi_session_files_json,
  pi_session_id,
  ephemeral,
  launch_idempotency_key,
  launch_source,
  launch_status,
  launch_lease_owner,
  launch_lease_until_ms,
  launch_metadata_json
`;

const SESSION_COLUMN_DEFINITIONS = [
  ["workspace_id", "TEXT"],
  ["workspace_name", "TEXT"],
  ["worktree_id", "TEXT"],
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
  ["runtime", "TEXT"],
  ["mirror_json", "TEXT"],
  ["pi_session_file", "TEXT"],
  ["pi_session_files_json", "TEXT"],
  ["pi_session_id", "TEXT"],
  ["ephemeral", "INTEGER NOT NULL DEFAULT 0"],
  ["agent_id", "TEXT"],
  ["agent_version", "INTEGER"],
  ["launch_source", "TEXT"],
  ["launch_status", "TEXT"],
  ["launch_lease_owner", "TEXT"],
  ["launch_lease_until_ms", "INTEGER"],
  ["parent_session_id", "TEXT"],
  ["todo_id", "TEXT"],
  ["goal_id", "TEXT"],
  ["schedule_id", "TEXT"],
  ["schedule_run_id", "TEXT"],
  ["launch_idempotency_key", "TEXT"],
  ["launch_metadata_json", "TEXT"],
  ["session_json", "TEXT NOT NULL DEFAULT ''"],
  ["updated_at", "INTEGER NOT NULL DEFAULT 0"],
] as const;

export class SessionSqliteStore {
  private readonly dataDir: string;
  private readonly db: SqliteDatabase;
  private cache: Map<string, Session> | null = null;

  private stmtUpsert!: SqliteStatement;
  private stmtGet!: SqliteStatement;
  private stmtList!: SqliteStatement;
  private stmtListIds!: SqliteStatement;
  private stmtDelete!: SqliteStatement;

  constructor(dataDir: string, dbPathOrOptions?: string | SessionSqliteStoreOptions) {
    if (!existsSync(dataDir)) {
      mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    }

    const options: SessionSqliteStoreOptions =
      typeof dbPathOrOptions === "string" ? { dbPath: dbPathOrOptions } : (dbPathOrOptions ?? {});

    this.dataDir = resolve(dataDir);
    const dbPath = resolve(options.dbPath ?? join(dataDir, "session-state.db"));
    this.db = openDatabase(dbPath);
    chmodSync(dbPath, 0o600);
    this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec("PRAGMA synchronous = NORMAL");
    this.ensureSchema();
    this.prepareStatements();
    this.importLegacyJsonOnce(dataDir);
  }

  close(): void {
    this.cache = null;
    this.db.close();
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
      runtime: "oppi",
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
      normalized.worktreeId ?? null,
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
      normalized.runtime ?? null,
      normalized.mirror ? JSON.stringify(normalized.mirror) : null,
      normalized.piSessionFile ?? null,
      normalized.piSessionFiles ? JSON.stringify(normalized.piSessionFiles) : null,
      normalized.piSessionId ?? null,
      normalized.ephemeral ? 1 : 0,
      normalized.launch?.agentId ?? null,
      normalized.launch?.agentVersion ?? null,
      normalized.launch?.source ?? null,
      normalized.launch?.status ?? null,
      normalized.launch?.lease?.owner ?? null,
      normalized.launch?.lease?.expiresAt ?? null,
      normalized.launch?.parentSessionId ?? null,
      normalized.launch?.todoId ?? null,
      normalized.launch?.goalId ?? null,
      normalized.launch?.schedule?.scheduleId ?? null,
      normalized.launch?.schedule?.runId ?? null,
      normalized.launch?.idempotencyKey ?? null,
      normalized.launch ? JSON.stringify(normalized.launch) : null,
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

  listAllWorkspaceSessionSnapshots(workspaceId: string, worktreeId?: string): Session[] {
    return this.queryWorkspaceProjectedSessions(workspaceId, { worktreeId });
  }

  listRecentWorkspaceSessionSnapshots(
    workspaceId: string,
    recentDays: number,
    nowMs: number = Date.now(),
    worktreeId?: string,
  ): Session[] {
    const normalizedRecentDays = normalizePositiveInteger(recentDays);
    if (!normalizedRecentDays) {
      return this.queryWorkspaceProjectedSessions(workspaceId, { worktreeId });
    }

    return this.queryWorkspaceProjectedSessions(workspaceId, {
      stoppedSinceMs: nowMs - normalizedRecentDays * 86_400_000,
      worktreeId,
    });
  }

  listWorkspaceTimeRangeSessionSnapshots(
    workspaceId: string,
    sinceMs: number,
    untilMs: number,
    worktreeId?: string,
  ): Session[] {
    return this.queryWorkspaceProjectedSessions(workspaceId, {
      stoppedSinceMs: normalizeTimestamp(sinceMs),
      stoppedUntilMs: normalizeTimestamp(untilMs),
      worktreeId,
    });
  }

  listStoppedWorkspaceTimeRangeSessionSnapshots(
    workspaceId: string,
    sinceMs: number,
    untilMs: number,
    worktreeId?: string,
  ): Session[] {
    return this.queryWorkspaceProjectedSessions(workspaceId, {
      status: "stopped",
      stoppedSinceMs: normalizeTimestamp(sinceMs),
      stoppedUntilMs: normalizeTimestamp(untilMs),
      worktreeId,
    });
  }

  listWorkspaceSessionSummarySnapshots(): WorkspaceSessionSummarySnapshot[] {
    const rows = this.db
      .prepare(
        `SELECT
           s.workspace_id AS workspace_id,
           MAX(s.last_activity) AS latest_activity,
           SUM(CASE WHEN s.status <> 'stopped' THEN 1 ELSE 0 END) AS active_count,
           SUM(CASE WHEN s.status = 'stopped' THEN 1 ELSE 0 END) AS stopped_count,
           MAX(CASE WHEN s.status = 'error' THEN 1 ELSE 0 END) AS has_error_root
         FROM session_state_sessions s
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
    worktreeId?: string,
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
           ${worktreeId ? "AND COALESCE(worktree_id, 'main') = ?" : ""}
         GROUP BY bucket_kind, bucket_key
         ORDER BY latest_activity DESC, bucket_key DESC`,
      )
      .all(
        recentDayCutoffMs,
        recentDayCutoffMs,
        workspaceId,
        beforeMs,
        ...(worktreeId ? [worktreeId] : []),
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

    // Legacy JSON sidecars are import-only now. Delete the sidecar too so a
    // session delete removes all session persistence, while the tombstone still
    // prevents an incomplete legacy import from resurrecting the session.
    this.deleteLegacyJsonSidecar(sessionId);
    this.markMigration(legacySessionDeleteMigrationKey(sessionId));

    return existed;
  }

  private deleteLegacyJsonSidecar(sessionId: string): void {
    const sessionsDir = resolve(this.dataDir, "sessions");
    const target = resolve(sessionsDir, `${sessionId}.json`);
    if (target !== sessionsDir && target.startsWith(`${sessionsDir}/`)) {
      rmSync(target, { force: true });
    }
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
        worktree_id TEXT,
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
        runtime TEXT,
        mirror_json TEXT,
        pi_session_file TEXT,
        pi_session_files_json TEXT,
        pi_session_id TEXT,
        ephemeral INTEGER NOT NULL DEFAULT 0,
        agent_id TEXT,
        agent_version INTEGER,
        launch_source TEXT,
        launch_status TEXT,
        launch_lease_owner TEXT,
        launch_lease_until_ms INTEGER,
        parent_session_id TEXT,
        todo_id TEXT,
        goal_id TEXT,
        schedule_id TEXT,
        schedule_run_id TEXT,
        launch_idempotency_key TEXT,
        launch_metadata_json TEXT,
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

      CREATE INDEX IF NOT EXISTS session_state_sessions_workspace_worktree_activity_idx
        ON session_state_sessions (workspace_id, worktree_id, last_activity DESC, id ASC);

      CREATE INDEX IF NOT EXISTS session_state_sessions_status_activity_idx
        ON session_state_sessions (status, last_activity DESC, id ASC);

      CREATE UNIQUE INDEX IF NOT EXISTS session_state_sessions_launch_idempotency_idx
        ON session_state_sessions (launch_idempotency_key)
        WHERE launch_idempotency_key IS NOT NULL;

      CREATE INDEX IF NOT EXISTS session_state_sessions_launch_schedule_idx
        ON session_state_sessions (schedule_id, schedule_run_id)
        WHERE schedule_id IS NOT NULL;

      CREATE TABLE IF NOT EXISTS session_state_schema (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS app_state_migrations (
        key TEXT PRIMARY KEY,
        completed_at INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS server_agent_extension_audit_events (
        id TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL,
        workspace_id TEXT,
        schedule_id TEXT,
        run_id TEXT,
        session_id TEXT,
        event_type TEXT NOT NULL,
        approval_ref_id TEXT,
        extension_scope_id TEXT,
        extension_display_name TEXT,
        display_json TEXT,
        provenance_json TEXT,
        envelope_json TEXT NOT NULL
      );

      CREATE INDEX IF NOT EXISTS server_agent_extension_audit_events_schedule_idx
        ON server_agent_extension_audit_events (schedule_id, created_at ASC, id ASC);

      CREATE INDEX IF NOT EXISTS server_agent_extension_audit_events_run_idx
        ON server_agent_extension_audit_events (run_id, created_at ASC, id ASC);

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
        worktree_id,
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
        runtime,
        mirror_json,
        pi_session_file,
        pi_session_files_json,
        pi_session_id,
        ephemeral,
        agent_id,
        agent_version,
        launch_source,
        launch_status,
        launch_lease_owner,
        launch_lease_until_ms,
        parent_session_id,
        todo_id,
        goal_id,
        schedule_id,
        schedule_run_id,
        launch_idempotency_key,
        launch_metadata_json,
        session_json,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        workspace_id = excluded.workspace_id,
        workspace_name = excluded.workspace_name,
        worktree_id = excluded.worktree_id,
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
        runtime = excluded.runtime,
        mirror_json = excluded.mirror_json,
        pi_session_file = excluded.pi_session_file,
        pi_session_files_json = excluded.pi_session_files_json,
        pi_session_id = excluded.pi_session_id,
        ephemeral = excluded.ephemeral,
        agent_id = excluded.agent_id,
        agent_version = excluded.agent_version,
        launch_source = excluded.launch_source,
        launch_status = excluded.launch_status,
        launch_lease_owner = excluded.launch_lease_owner,
        launch_lease_until_ms = excluded.launch_lease_until_ms,
        parent_session_id = excluded.parent_session_id,
        todo_id = excluded.todo_id,
        goal_id = excluded.goal_id,
        schedule_id = excluded.schedule_id,
        schedule_run_id = excluded.schedule_run_id,
        launch_idempotency_key = excluded.launch_idempotency_key,
        launch_metadata_json = excluded.launch_metadata_json,
        session_json = excluded.session_json,
        updated_at = excluded.updated_at
    `);

    this.stmtGet = this.db.prepare("SELECT session_json FROM session_state_sessions WHERE id = ?");
    this.stmtList = this.db.prepare(`
      SELECT session_json
      FROM session_state_sessions
      ORDER BY last_activity DESC, id ASC
    `);
    this.stmtListIds = this.db.prepare("SELECT id FROM session_state_sessions");
    this.stmtDelete = this.db.prepare("DELETE FROM session_state_sessions WHERE id = ?");
  }

  findSessionByLaunchIdempotencyKey(idempotencyKey: string): Session | undefined {
    const key = idempotencyKey.trim();
    if (!key) return undefined;
    const row = this.db
      .prepare("SELECT session_json FROM session_state_sessions WHERE launch_idempotency_key = ?")
      .get(key) as SessionJsonRow | undefined;
    const session = row ? this.parseSession(row.session_json) : undefined;
    return session ? stripInternalFields(session) : undefined;
  }

  claimSessionLaunchRecovery(
    session: Session,
    leaseOwner: string,
    nowMs: number,
    leaseTtlMs: number,
  ): Session | undefined {
    const launch = session.launch;
    if (!launch?.idempotencyKey) return undefined;

    const recovered = normalizeDeclaredSession(
      this.restoreInternalFields({
        ...session,
        launch: {
          ...launch,
          status: "launching",
          lease: {
            owner: leaseOwner,
            acquiredAt: nowMs,
            expiresAt: nowMs + leaseTtlMs,
          },
        },
      }),
    );
    const json = JSON.stringify(recovered);
    const expectedLeaseOwner = launch.lease?.owner ?? null;
    const expectedLeaseExpiresAt = launch.lease?.expiresAt ?? null;

    const result = this.db
      .prepare(
        `UPDATE session_state_sessions
         SET launch_status = ?,
             launch_lease_owner = ?,
             launch_lease_until_ms = ?,
             launch_metadata_json = ?,
             session_json = ?,
             updated_at = ?
         WHERE id = ?
           AND launch_idempotency_key = ?
           AND launch_status = ?
           AND ((? IS NULL AND launch_lease_owner IS NULL) OR launch_lease_owner = ?)
           AND ((? IS NULL AND launch_lease_until_ms IS NULL) OR launch_lease_until_ms = ?)`,
      )
      .run(
        recovered.launch?.status ?? null,
        recovered.launch?.lease?.owner ?? null,
        recovered.launch?.lease?.expiresAt ?? null,
        recovered.launch ? JSON.stringify(recovered.launch) : null,
        json,
        Date.now(),
        session.id,
        launch.idempotencyKey,
        launch.status,
        expectedLeaseOwner,
        expectedLeaseOwner,
        expectedLeaseExpiresAt,
        expectedLeaseExpiresAt,
      ) as { changes?: number };

    if (result.changes !== 1) return undefined;

    const stripped = stripInternalFields(recovered);
    this.cache?.set(recovered.id, stripped);
    return stripped;
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
      worktreeId?: string;
    } = {},
  ): Session[] {
    const whereParts = ["workspace_id = ?"];
    const params: unknown[] = [workspaceId];

    if (filters.status) {
      whereParts.push("status = ?");
      params.push(filters.status);
    }

    if (filters.worktreeId) {
      whereParts.push("COALESCE(worktree_id, 'main') = ?");
      params.push(filters.worktreeId);
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

    return this.parseProjectedRows(rows);
  }
}

function normalizeStoredSessionRuntimeKind(value: unknown): Session["runtime"] | undefined {
  if (value === "oppi" || value === "pi-tui") {
    return value;
  }
  if (value === "managed") {
    return "oppi";
  }
  if (value === "pi-tui-mirror") {
    return "pi-tui";
  }
  return undefined;
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
  if (row.worktree_id !== null) session.worktreeId = row.worktree_id;
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
  session.runtime = normalizeStoredSessionRuntimeKind(row.runtime) ?? "oppi";
  const mirror = parseJsonValue<Session["mirror"]>(row.mirror_json, row.id, "mirror");
  if (mirror) session.mirror = mirror;
  if (row.pi_session_file !== null) session.piSessionFile = row.pi_session_file;
  if (row.pi_session_id !== null) session.piSessionId = row.pi_session_id;
  if (row.ephemeral !== 0) session.ephemeral = true;

  const launch = parseJsonValue<Session["launch"]>(row.launch_metadata_json, row.id, "launch");
  if (launch) session.launch = launch;

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

/** Backfill cache token fields for sessions persisted before cacheRead/cacheWrite existed. */
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
    tokens: normalizeSessionTokens(session.tokens),
    cost: session.cost ?? 0,
  };

  if (session.workspaceId !== undefined && session.workspaceId !== null) {
    normalized.workspaceId = session.workspaceId;
  }
  if (session.workspaceName !== undefined && session.workspaceName !== null) {
    normalized.workspaceName = session.workspaceName;
  }
  if (session.worktreeId !== undefined && session.worktreeId !== null) {
    normalized.worktreeId = session.worktreeId;
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
  normalized.runtime = normalizeStoredSessionRuntimeKind(session.runtime) ?? "oppi";
  if (session.mirror !== undefined && session.mirror !== null) {
    normalized.mirror = session.mirror;
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
  if (session.launch !== undefined && session.launch !== null) {
    normalized.launch = session.launch;
  }
  if (session.launch !== undefined && session.launch !== null) {
    normalized.launch = session.launch;
  }
  if (session.ephemeral === true) {
    normalized.ephemeral = true;
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
