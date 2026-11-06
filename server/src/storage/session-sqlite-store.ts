import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";

import { mintSessionId } from "../id.js";
import { ICON_ASSET_ID_PATTERN, migrateIconChoice, validateIconChoice } from "../icon-choice.js";
import { createLogger } from "../logger.js";
import { safeErrorMessage } from "../log-utils.js";
import type { ChatAttachmentRef, Session } from "../types.js";
import { openDatabase, type SqliteDatabase, type SqliteStatement } from "../sqlite-compat.js";
import {
  createSessionStateSessionsTable,
  runSessionColumnsRecordMigration,
} from "./session-columns-record-migration.js";
import type { WorkspaceSessionSummarySnapshot } from "./session-dao.js";
import {
  ensureMigrationsTable,
  hasCompletedMigration,
  recordMigration,
  runSessionInteractionsDrop,
  runSessionStateDeadSchemaCleanup,
} from "./session-state-cleanup-migration.js";
import {
  backfillContextTokensFromTrace,
  backfillCostFromTokens,
  normalizeSessionTokens,
} from "./session-repair.js";
import { isRecord } from "../json-shape.js";

const log = createLogger({ base: { component: "session_sqlite_store" } });
const SCHEMA_VERSION = "10";

interface SessionRow {
  id: string;
  workspace_id: string | null;
  worktree_id: string | null;
  name: string | null;
  status: Session["status"];
  created_at: number;
  last_activity: number;
  current_turn_started_at: number | null;
  warnings_json: string | null;
  runtime: Session["runtime"] | null;
  mirror_json: string | null;
  pi_session_file: string | null;
  pi_session_files_json: string | null;
  ephemeral: number;
  launch_metadata_json: string | null;
  durable_store_id: string | null;
  durable_conversation_id: number | null;
  durable_role: string | null;
  control_json: string | null;
  program_status_json: string | null;
  summary_json: string;
}

/**
 * Conversation stats cached in `summary_json`. None of these is filtered or sorted in SQL; a
 * durable session can refresh them from its store.
 */
type SessionSummaryCache = Partial<
  Pick<
    Session,
    | "model"
    | "thinkingLevel"
    | "messageCount"
    | "tokens"
    | "cost"
    | "firstMessage"
    | "lastMessage"
    | "contextTokens"
    | "contextWindow"
    | "lastAgentReplyAt"
    | "changeStats"
  >
>;

interface WorkspaceSummaryRow {
  workspace_id: string;
  latest_activity: number | null;
  active_count: number;
  stopped_count: number;
  has_error_root: number;
}

export interface SessionSqliteStoreOptions {
  dbPath?: string;
}

/** A session to bring back after a server restart. */
export interface RestartResumeEntry {
  sessionId: string;
  /** Mid-turn when the previous process ended; the resume sends a continuation. */
  wasBusy: boolean;
}

/**
 * A message a session received while the server drained for a restart. It is delivered to the
 * session after the restart (or when the drain is cancelled), oldest first.
 */
export interface HeldInput {
  id: number;
  sessionId: string;
  message: string;
  attachments?: ChatAttachmentRef[];
  /** The sender's turn id: a resend of the same turn is held once, and Durable dedupes delivery. */
  clientTurnId?: string;
  heldAt: number;
}

/** Everything `buildSession` decodes. The launch CAS columns are read only by their queries. */
const SESSION_COLUMNS = `
  id,
  workspace_id,
  worktree_id,
  name,
  status,
  created_at,
  last_activity,
  current_turn_started_at,
  warnings_json,
  runtime,
  mirror_json,
  pi_session_file,
  pi_session_files_json,
  ephemeral,
  launch_metadata_json,
  durable_store_id,
  durable_conversation_id,
  durable_role,
  control_json,
  program_status_json,
  summary_json
`;

export class SessionSqliteStore {
  private readonly dataDir: string;
  private readonly db: SqliteDatabase;
  private cache: Map<string, Session> | null = null;

  private stmtUpsert!: SqliteStatement;
  private stmtClaimLaunch!: SqliteStatement;
  private stmtGet!: SqliteStatement;
  private stmtList!: SqliteStatement;
  private stmtFindDurable!: SqliteStatement;
  private stmtListDurableStore!: SqliteStatement;
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
  }

  close(): void {
    this.cache = null;
    this.db.close();
  }

  createSession(name?: string, model?: string, options?: { id?: string }): Session {
    const now = Date.now();
    const id = options?.id ?? mintSessionId();
    const session: Session = {
      id,
      name,
      status: "ready",
      createdAt: now,
      lastActivity: now,
      programStatus: { state: "idle", since: now },
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
    const normalized = normalizeDeclaredSession(session);
    this.stmtUpsert.run(normalized.id, ...sessionRowValues(normalized));
    this.cache?.set(normalized.id, normalized);
  }

  getSession(sessionId: string): Session | undefined {
    const cached = this.cache?.get(sessionId);
    if (cached) return cached;

    const session = this.getSessionFromDb(sessionId);
    if (!session) return undefined;

    this.cache?.set(session.id, session);
    return session;
  }

  listSessions(): Session[] {
    return sortSessions(Array.from(this.ensureCache().values()));
  }

  /**
   * Session for a durable conversation, by the `(durable_store_id, durable_conversation_id)`
   * index. Conversation ids are per store, so both are required.
   */
  findSessionByDurableConversation(storeId: string, conversationId: number): Session | undefined {
    const row = this.stmtFindDurable.get(storeId, conversationId) as { id: string } | undefined;
    return row ? this.getSession(row.id) : undefined;
  }

  /**
   * Sessions bound to a conversation of durable store `storeId`: the store's rows by the
   * `(durable_store_id, durable_conversation_id)` index, not a sorted copy of every session.
   */
  listDurableStoreSessions(storeId: string): Session[] {
    const rows = this.stmtListDurableStore.all(storeId) as Array<{ id: string }>;
    return rows.flatMap((row) => this.getSession(row.id) ?? []);
  }

  /** Whether any session names durable store `storeId`, bound to a conversation yet or not. */
  hasDurableStoreSessions(storeId: string): boolean {
    return (
      this.db
        .prepare("SELECT 1 FROM session_state_sessions WHERE durable_store_id = ? LIMIT 1")
        .get(storeId) !== undefined
    );
  }

  /**
   * Scans launch metadata without full Session decoding, so a row that fails to decode cannot
   * hide a valid tagged Genmoji reference.
   */
  listReferencedIconAssetIds(): Set<string> {
    const rows = this.db
      .prepare(
        "SELECT launch_metadata_json FROM session_state_sessions WHERE launch_metadata_json IS NOT NULL",
      )
      .all() as Array<{ launch_metadata_json: string }>;
    const assetIds = new Set<string>();

    for (const row of rows) {
      try {
        collectStoredIconAssetIds(JSON.parse(row.launch_metadata_json) as unknown, assetIds);
      } catch {
        // Malformed launch metadata names no asset.
      }
    }
    return assetIds;
  }

  listSessionsWithoutWorkspace(): Session[] {
    const rows = this.db
      .prepare(
        `SELECT ${SESSION_COLUMNS}
         FROM session_state_sessions
         WHERE workspace_id IS NULL
         ORDER BY last_activity DESC, id ASC`,
      )
      .all() as SessionRow[];
    return this.decodeRows(rows);
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

  /**
   * Activity times of a workspace's stopped sessions before `beforeMs`, newest first. The
   * session list service groups them into older-history sections with local Pi sessions.
   */
  listWorkspaceStoppedActivityTimes(
    workspaceId: string,
    beforeMs: number,
    worktreeId?: string,
  ): number[] {
    const rows = this.db
      .prepare(
        `SELECT last_activity
         FROM session_state_sessions
         WHERE workspace_id = ?
           AND status = 'stopped'
           AND last_activity < ?
           ${worktreeId ? "AND COALESCE(worktree_id, 'main') = ?" : ""}
         ORDER BY last_activity DESC`,
      )
      .all(workspaceId, beforeMs, ...(worktreeId ? [worktreeId] : [])) as {
      last_activity: number;
    }[];
    return rows.map((row) => row.last_activity);
  }

  deleteSession(sessionId: string): boolean {
    this.clearHeldInputs(sessionId);
    const result = this.stmtDelete.run(sessionId) as { changes?: number };
    this.cache?.delete(sessionId);
    return (result.changes ?? 0) > 0;
  }

  /**
   * Queue sessions to resume after the next server start. A session queued
   * twice stays busy if either record saw it mid-turn.
   */
  queueRestartResume(entries: readonly RestartResumeEntry[], recordedAt: number): void {
    if (entries.length === 0) return;
    const upsert = this.db.prepare(
      `INSERT INTO session_restart_resume (session_id, was_busy, recorded_at)
       VALUES (?, ?, ?)
       ON CONFLICT(session_id) DO UPDATE SET
         was_busy = MAX(was_busy, excluded.was_busy),
         recorded_at = excluded.recorded_at`,
    );
    this.db.transaction(() => {
      for (const entry of entries) {
        upsert.run(entry.sessionId, entry.wasBusy ? 1 : 0, recordedAt);
      }
    })();
  }

  listRestartResume(): RestartResumeEntry[] {
    const rows = this.db
      .prepare(
        "SELECT session_id, was_busy FROM session_restart_resume ORDER BY recorded_at ASC, session_id ASC",
      )
      .all() as Array<{ session_id: string; was_busy: number }>;
    return rows.map((row) => ({ sessionId: row.session_id, wasBusy: row.was_busy === 1 }));
  }

  /**
   * Runs `run` once per data directory: the first call under `key` runs it and records the key
   * in the migration ledger, later calls do not. A `run` that throws is not recorded, so the
   * next start tries again.
   */
  async runMigrationOnce(key: string, run: () => Promise<void>): Promise<boolean> {
    ensureMigrationsTable(this.db);
    if (hasCompletedMigration(this.db, key)) return false;
    await run();
    recordMigration(this.db, key);
    return true;
  }

  clearRestartResume(sessionId: string): void {
    this.db.prepare("DELETE FROM session_restart_resume WHERE session_id = ?").run(sessionId);
  }

  /** Hold one input for after the restart. False when this turn id is already held. */
  holdInput(input: Omit<HeldInput, "id">): boolean {
    const result = this.db
      .prepare(
        `INSERT OR IGNORE INTO session_held_input
           (session_id, message, attachments_json, client_turn_id, held_at)
         VALUES (?, ?, ?, ?, ?)`,
      )
      .run(
        input.sessionId,
        input.message,
        input.attachments?.length ? JSON.stringify(input.attachments) : null,
        input.clientTurnId ?? null,
        input.heldAt,
      ) as { changes?: number };
    return (result.changes ?? 0) > 0;
  }

  /** Held inputs, oldest first; one session's when `sessionId` is given. */
  listHeldInputs(sessionId?: string): HeldInput[] {
    const rows = (
      sessionId === undefined
        ? this.db.prepare("SELECT * FROM session_held_input ORDER BY id ASC").all()
        : this.db
            .prepare("SELECT * FROM session_held_input WHERE session_id = ? ORDER BY id ASC")
            .all(sessionId)
    ) as Array<{
      id: number;
      session_id: string;
      message: string;
      attachments_json: string | null;
      client_turn_id: string | null;
      held_at: number;
    }>;
    return rows.map((row) => ({
      id: row.id,
      sessionId: row.session_id,
      message: row.message,
      ...(row.attachments_json
        ? { attachments: JSON.parse(row.attachments_json) as ChatAttachmentRef[] }
        : {}),
      ...(row.client_turn_id ? { clientTurnId: row.client_turn_id } : {}),
      heldAt: row.held_at,
    }));
  }

  deleteHeldInput(id: number): void {
    this.db.prepare("DELETE FROM session_held_input WHERE id = ?").run(id);
  }

  clearHeldInputs(sessionId: string): number {
    const result = this.db
      .prepare("DELETE FROM session_held_input WHERE session_id = ?")
      .run(sessionId) as { changes?: number };
    return result.changes ?? 0;
  }

  private ensureSchema(): void {
    const hasSessionTable = this.db
      .prepare(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='session_state_sessions'",
      )
      .get();

    if (!hasSessionTable) {
      createSessionStateSessionsTable(this.db, "session_state_sessions");
    }
    // Ordered: the dead-schema cleanup drops columns of the old table shape before the rebuild.
    runSessionStateDeadSchemaCleanup(this.db, this.dataDir);
    runSessionColumnsRecordMigration(this.db, this.dataDir);
    runSessionInteractionsDrop(this.db, this.dataDir);
    this.ensureSessionIndexesAndSchemaVersion();
    this.migrateStoredIconChoices();
  }

  private ensureSessionIndexesAndSchemaVersion(): void {
    this.db.exec(`
      CREATE INDEX IF NOT EXISTS session_state_sessions_workspace_activity_idx
        ON session_state_sessions (workspace_id, last_activity DESC, id ASC);

      CREATE UNIQUE INDEX IF NOT EXISTS session_state_sessions_launch_idempotency_idx
        ON session_state_sessions (launch_idempotency_key)
        WHERE launch_idempotency_key IS NOT NULL;

      CREATE INDEX IF NOT EXISTS session_state_sessions_durable_idx
        ON session_state_sessions (durable_store_id, durable_conversation_id)
        WHERE durable_store_id IS NOT NULL;

      CREATE TABLE IF NOT EXISTS session_restart_resume (
        session_id TEXT PRIMARY KEY,
        was_busy INTEGER NOT NULL,
        recorded_at INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS session_held_input (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        message TEXT NOT NULL,
        attachments_json TEXT,
        client_turn_id TEXT,
        held_at INTEGER NOT NULL
      );

      CREATE UNIQUE INDEX IF NOT EXISTS session_held_input_turn_idx
        ON session_held_input (session_id, client_turn_id)
        WHERE client_turn_id IS NOT NULL;

      CREATE TABLE IF NOT EXISTS session_state_schema (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );

      INSERT OR REPLACE INTO session_state_schema (key, value)
      VALUES ('version', '${SCHEMA_VERSION}');
    `);
  }

  /** Normalizes historical icon values inside stored launch metadata. */
  private migrateStoredIconChoices(): void {
    const rows = this.db
      .prepare(
        "SELECT id, launch_metadata_json FROM session_state_sessions WHERE launch_metadata_json IS NOT NULL",
      )
      .all() as Array<{ id: string; launch_metadata_json: string }>;
    const update = this.db.prepare(
      "UPDATE session_state_sessions SET launch_metadata_json = ? WHERE id = ?",
    );

    this.db.transaction(() => {
      for (const row of rows) {
        const launch = parseStoredLaunch(row.launch_metadata_json);
        if (!launch) continue;
        const launchJson = JSON.stringify(launch);
        if (launchJson !== row.launch_metadata_json) {
          update.run(launchJson, row.id);
        }
      }
    })();
  }

  private prepareStatements(): void {
    this.stmtUpsert = this.db.prepare(`
      INSERT INTO session_state_sessions (id, ${SESSION_WRITE_COLUMNS.join(", ")})
      VALUES (?, ${SESSION_WRITE_COLUMNS.map(() => "?").join(", ")})
      ON CONFLICT(id) DO UPDATE SET
        ${SESSION_WRITE_COLUMNS.map((column) => `${column} = excluded.${column}`).join(",\n        ")}
    `);
    this.stmtClaimLaunch = this.db.prepare(`
      UPDATE session_state_sessions
      SET ${SESSION_WRITE_COLUMNS.map((column) => `${column} = ?`).join(", ")}
      WHERE id = ?
        AND launch_idempotency_key = ?
        AND launch_status = ?
        AND ((? IS NULL AND launch_lease_owner IS NULL) OR launch_lease_owner = ?)
        AND ((? IS NULL AND launch_lease_until_ms IS NULL) OR launch_lease_until_ms = ?)
    `);

    this.stmtGet = this.db.prepare(
      `SELECT ${SESSION_COLUMNS} FROM session_state_sessions WHERE id = ?`,
    );
    this.stmtList = this.db.prepare(`
      SELECT ${SESSION_COLUMNS}
      FROM session_state_sessions
      ORDER BY last_activity DESC, id ASC
    `);
    this.stmtFindDurable = this.db.prepare(`
      SELECT id
      FROM session_state_sessions
      WHERE durable_store_id = ? AND durable_conversation_id = ?
      ORDER BY created_at ASC, id ASC
      LIMIT 1
    `);
    this.stmtListDurableStore = this.db.prepare(`
      SELECT id
      FROM session_state_sessions
      WHERE durable_store_id = ? AND durable_conversation_id IS NOT NULL
    `);
    this.stmtDelete = this.db.prepare("DELETE FROM session_state_sessions WHERE id = ?");
  }

  findSessionByLaunchIdempotencyKey(idempotencyKey: string): Session | undefined {
    const key = idempotencyKey.trim();
    if (!key) return undefined;
    const row = this.db
      .prepare(
        `SELECT ${SESSION_COLUMNS} FROM session_state_sessions WHERE launch_idempotency_key = ?`,
      )
      .get(key) as SessionRow | undefined;
    return row ? this.decodeRow(row) : undefined;
  }

  claimSessionLaunchRecovery(
    session: Session,
    leaseOwner: string,
    nowMs: number,
    leaseTtlMs: number,
  ): Session | undefined {
    const launch = session.launch;
    if (!launch?.idempotencyKey) return undefined;

    // The claim is one autocommit compare-and-swap: another connection that took the lease
    // first makes it match no row instead of failing a stale transaction.
    const recovered = normalizeDeclaredSession({
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
    });
    const expectedLeaseOwner = launch.lease?.owner ?? null;
    const expectedLeaseExpiresAt = launch.lease?.expiresAt ?? null;

    const result = this.stmtClaimLaunch.run(
      ...sessionRowValues(recovered),
      session.id,
      launch.idempotencyKey,
      launch.status,
      expectedLeaseOwner,
      expectedLeaseOwner,
      expectedLeaseExpiresAt,
      expectedLeaseExpiresAt,
    ) as { changes?: number };
    if (result.changes !== 1) return undefined;

    this.cache?.set(recovered.id, recovered);
    return recovered;
  }

  private ensureCache(): Map<string, Session> {
    if (this.cache) {
      return this.cache;
    }

    this.cache = new Map();
    for (const session of this.decodeRows(this.stmtList.all() as SessionRow[])) {
      this.cache.set(session.id, session);
    }
    return this.cache;
  }

  private decodeRows(rows: SessionRow[]): Session[] {
    const sessions: Session[] = [];
    for (const row of rows) {
      const session = this.decodeRow(row);
      if (session) {
        sessions.push(session);
      }
    }
    return sessions;
  }

  /** Full read: the row plus the read-time repairs every `Session` gets. */
  private decodeRow(row: SessionRow): Session | undefined {
    try {
      return normalizeDeclaredSession(buildSession(row));
    } catch (error) {
      log.error("session_sqlite_store.row_parse.failed", {
        sessionId: row.id,
        error: safeErrorMessage(error),
      });
      return undefined;
    }
  }

  private getSessionFromDb(sessionId: string): Session | undefined {
    const row = this.stmtGet.get(sessionId) as SessionRow | undefined;
    return row ? this.decodeRow(row) : undefined;
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
        `SELECT ${SESSION_COLUMNS}
         FROM session_state_sessions
         WHERE ${whereSql}
         ORDER BY last_activity DESC, id ASC`,
      )
      .all(...params) as SessionRow[];

    // Lists skip the full-read repairs but still drop pre-0.53 change-stat keys.
    return rows.map((row) => {
      const session = buildSession(row);
      if (session.changeStats) session.changeStats = projectChangeStats(session.changeStats);
      return session;
    });
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

/**
 * The one row decoder. Full reads add the repairs (`normalizeDeclaredSession`); workspace
 * lists add only the change-stat projection.
 */
function buildSession(row: SessionRow): Session {
  // Neither writer stores null members, so the cached fields copy over as they are.
  const {
    messageCount = 0,
    tokens,
    cost = 0,
    ...cached
  } = parseJsonValue<SessionSummaryCache>(row.summary_json, row.id, "summary") ?? {};
  const session: Session = Object.assign(
    {
      id: row.id,
      status: row.status,
      createdAt: row.created_at,
      lastActivity: row.last_activity,
      messageCount,
      tokens: normalizeSessionTokens(tokens),
      cost,
    },
    cached,
  );

  if (row.workspace_id !== null) session.workspaceId = row.workspace_id;
  if (row.worktree_id !== null) session.worktreeId = row.worktree_id;
  if (row.name !== null) session.name = row.name;
  if (row.current_turn_started_at !== null)
    session.currentTurnStartedAt = row.current_turn_started_at;
  session.runtime = normalizeStoredSessionRuntimeKind(row.runtime) ?? "oppi";
  const mirror = parseJsonValue<Session["mirror"]>(row.mirror_json, row.id, "mirror");
  if (mirror) session.mirror = mirror;
  if (row.pi_session_file !== null) session.piSessionFile = row.pi_session_file;
  if (row.ephemeral !== 0) session.ephemeral = true;

  const launch = parseJsonValue<Session["launch"]>(row.launch_metadata_json, row.id, "launch");
  if (launch) session.launch = launch;

  if (row.durable_store_id !== null || row.durable_conversation_id !== null || row.durable_role) {
    session.serverDurable = {
      ...(row.durable_store_id !== null ? { storeId: row.durable_store_id } : {}),
      ...(row.durable_conversation_id !== null
        ? { conversationId: row.durable_conversation_id }
        : {}),
      ...(row.durable_role === "control" ? { role: "control" as const } : {}),
    };
  }

  const control = parseJsonValue<Session["control"]>(row.control_json, row.id, "control");
  if (control) session.control = control;

  const programStatus = parseJsonValue<Session["programStatus"]>(
    row.program_status_json,
    row.id,
    "programStatus",
  );
  if (programStatus) session.programStatus = programStatus;

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

/**
 * Known fields only: rows saved before 0.53 also hold estimated line counts and a
 * per-file line-count map that must not reach clients or stay in memory.
 */
function projectChangeStats(stats: NonNullable<Session["changeStats"]>): Session["changeStats"] {
  return {
    mutatingToolCalls: stats.mutatingToolCalls,
    ...(stats.compactionCount !== undefined ? { compactionCount: stats.compactionCount } : {}),
    filesChanged: stats.filesChanged,
    changedFiles: stats.changedFiles,
    ...(stats.changedFilesOverflow !== undefined
      ? { changedFilesOverflow: stats.changedFilesOverflow }
      : {}),
    ...(stats.worktree ? { worktree: stats.worktree } : {}),
  };
}

/** Columns every write sets, after `id`; `sessionRowValues` returns values in this order. */
const SESSION_WRITE_COLUMNS = [
  "workspace_id",
  "worktree_id",
  "name",
  "status",
  "created_at",
  "last_activity",
  "current_turn_started_at",
  "warnings_json",
  "runtime",
  "mirror_json",
  "pi_session_file",
  "pi_session_files_json",
  "ephemeral",
  "launch_status",
  "launch_lease_owner",
  "launch_lease_until_ms",
  "launch_idempotency_key",
  "launch_metadata_json",
  "durable_store_id",
  "durable_conversation_id",
  "durable_role",
  "control_json",
  "program_status_json",
  "summary_json",
] as const;

function sessionRowValues(session: Session): unknown[] {
  return [
    session.workspaceId ?? null,
    session.worktreeId ?? null,
    session.name ?? null,
    session.status,
    session.createdAt,
    session.lastActivity,
    session.currentTurnStartedAt ?? null,
    session.warnings ? JSON.stringify(session.warnings) : null,
    session.runtime ?? null,
    session.mirror ? JSON.stringify(session.mirror) : null,
    session.piSessionFile ?? null,
    session.piSessionFiles ? JSON.stringify(session.piSessionFiles) : null,
    session.ephemeral ? 1 : 0,
    session.launch?.status ?? null,
    session.launch?.lease?.owner ?? null,
    session.launch?.lease?.expiresAt ?? null,
    session.launch?.idempotencyKey ?? null,
    session.launch ? JSON.stringify(session.launch) : null,
    session.serverDurable?.storeId ?? null,
    session.serverDurable?.conversationId ?? null,
    session.serverDurable?.role ?? null,
    session.control ? JSON.stringify(session.control) : null,
    session.programStatus ? JSON.stringify(session.programStatus) : null,
    encodeSummaryCache(session),
  ];
}

function encodeSummaryCache(session: Session): string {
  const summary: SessionSummaryCache = {
    model: session.model,
    thinkingLevel: session.thinkingLevel,
    messageCount: session.messageCount,
    tokens: session.tokens,
    cost: session.cost,
    firstMessage: session.firstMessage,
    lastMessage: session.lastMessage,
    contextTokens: session.contextTokens,
    contextWindow: session.contextWindow,
    lastAgentReplyAt: session.lastAgentReplyAt,
    changeStats: session.changeStats,
  };
  return JSON.stringify(summary);
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
  if (session.programStatus !== undefined && session.programStatus !== null) {
    normalized.programStatus = { ...session.programStatus };
  }
  if (session.model !== undefined && session.model !== null) {
    normalized.model = session.model;
  }
  if (session.changeStats !== undefined && session.changeStats !== null) {
    normalized.changeStats = projectChangeStats(session.changeStats);
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
  // An empty binding (no store, conversation, or role) has no columns to live in, so it is
  // dropped here and the cache agrees with what a later read decodes.
  if (
    session.serverDurable !== undefined &&
    (session.serverDurable.storeId !== undefined ||
      session.serverDurable.conversationId !== undefined ||
      session.serverDurable.role === "control")
  ) {
    const id = session.serverDurable.conversationId;
    if (id !== undefined && (!Number.isSafeInteger(id) || id <= 0)) {
      throw new Error("Invalid server durable conversation binding");
    }
    const storeId = session.serverDurable.storeId;
    if (storeId !== undefined && (typeof storeId !== "string" || storeId.length === 0)) {
      throw new Error("Invalid server durable store binding");
    }
    normalized.serverDurable = {
      ...(storeId === undefined ? {} : { storeId }),
      ...(id === undefined ? {} : { conversationId: id }),
      ...(session.serverDurable.role === "control" ? { role: "control" as const } : {}),
    };
  }
  if (session.control !== undefined && session.control !== null) {
    normalized.control = { ...session.control };
  }
  if (session.mirror !== undefined && session.mirror !== null) {
    normalized.mirror = session.mirror;
  }
  if (session.piSessionFile !== undefined && session.piSessionFile !== null) {
    normalized.piSessionFile = session.piSessionFile;
  }
  if (session.piSessionFiles && session.piSessionFiles.length > 0) {
    normalized.piSessionFiles = [...session.piSessionFiles];
  }
  if (session.launch !== undefined && session.launch !== null) {
    normalized.launch = normalizeStoredLaunchIcon(session.launch) as unknown as Session["launch"];
  }
  if (session.ephemeral === true) {
    normalized.ephemeral = true;
  }

  backfillCostFromTokens(normalized);
  backfillContextTokensFromTrace(normalized);

  return normalized;
}

function parseStoredLaunch(rawJson: string): Record<string, unknown> | undefined {
  try {
    return normalizeStoredLaunchIcon(JSON.parse(rawJson) as unknown, true);
  } catch {
    return undefined;
  }
}

/**
 * GC is deliberately more conservative than protocol decoding. Any valid
 * opaque asset ID found in parsed stored JSON may be a future or malformed
 * Genmoji reference, so retaining a false positive is safer than deleting a
 * blob still named by stored launch metadata.
 */
function collectStoredIconAssetIds(value: unknown, assetIds: Set<string>): void {
  if (Array.isArray(value)) {
    for (const entry of value) collectStoredIconAssetIds(entry, assetIds);
    return;
  }
  if (!isRecord(value)) return;

  if (typeof value.assetId === "string" && ICON_ASSET_ID_PATTERN.test(value.assetId)) {
    assetIds.add(value.assetId);
  }
  for (const nested of Object.values(value)) collectStoredIconAssetIds(nested, assetIds);
}

/** Normalize historical icon values inside otherwise opaque launch metadata. */
function normalizeStoredLaunchIcon(
  value: unknown,
  preserveOpaqueTaggedIcon = false,
): Record<string, unknown> | undefined {
  if (!isRecord(value)) return undefined;
  const launch = { ...value };
  const agentId = typeof launch.agentId === "string" ? launch.agentId.trim() : "";
  if (agentId) {
    launch.agentIcon = preserveOpaqueTaggedIcon
      ? migrateDurableLaunchIcon(launch.agentIcon)
      : migrateIconChoice(launch.agentIcon);
  } else {
    delete launch.agentIcon;
  }
  return launch;
}

/**
 * Durable launch snapshots are forward-compatible storage, not a protocol
 * validation boundary. Preserve tagged values that this version cannot decode
 * so startup migration cannot erase future fields or syntactic asset references.
 */
function migrateDurableLaunchIcon(value: unknown): unknown {
  if (isRecord(value) && typeof value.kind === "string") {
    try {
      return validateIconChoice(value);
    } catch {
      return value;
    }
  }
  return migrateIconChoice(value);
}

function sortSessions(sessions: Session[]): Session[] {
  return [...sessions].sort((a, b) => {
    if (b.lastActivity !== a.lastActivity) {
      return b.lastActivity - a.lastActivity;
    }
    return a.id.localeCompare(b.id);
  });
}
