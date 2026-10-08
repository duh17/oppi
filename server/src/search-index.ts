/**
 * SQLite FTS5-backed full-text search index for session content.
 *
 * Indexes user messages, assistant text, tool names, and session title
 * for fast keyword search across all sessions. The index lives in a
 * SQLite database file alongside the session data.
 *
 * Lifecycle:
 * - Server boot: open db, incremental sync (JSONL state + session metadata)
 * - Live: re-index on agent_end (debounced mark + immediate flush)
 * - Shutdown: close db
 */

import { openDatabase, type SqliteDatabase, type SqliteStatement } from "./sqlite-compat.js";
import { statSync } from "node:fs";
import { join } from "node:path";

import type { Session } from "./types.js";
import { createLogger } from "./logger.js";
import { isServerDurableSession } from "./session-runtime-capabilities.js";
import { extractSearchTranscriptFromFile, type SearchTranscriptContent } from "./trace.js";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface SearchResult {
  sessionId: string;
  workspaceId: string;
  title: string;
  snippet: string;
  rank: number;
  updatedAtMs?: number;
}

export interface SearchFilters {
  sinceMs?: number;
  untilMs?: number;
}

/**
 * Read-only access to server-durable history. Durable sessions have no JSONL
 * file, so freshness is the conversation's newest entry id and content comes
 * from the same entry projection the trace routes use.
 */
export interface DurableSearchSource {
  /** Newest entry id for the conversation ("" when it has no entries). */
  readTipEntryId(conversationId: number): Promise<string>;
  readTranscript(conversationId: number): Promise<SearchTranscriptContent>;
}

export interface SearchIndexSyncResult {
  reindexed: number;
  added: number;
  removed: number;
  skipped: number;
  transcriptsRead: number;
  transcriptBytesRead: number;
  reusedIndexedTranscript: number;
  transcriptsReindexed: number;
}

export interface SearchIndexBackgroundSyncOptions {
  /** Maximum session count in one transaction. Primarily useful for deterministic tests. */
  batchSize?: number;
  /** Target amount of synchronous work per event-loop turn. A single session may exceed it. */
  budgetMs?: number;
  /** Override the Node event-loop yield in deterministic tests. */
  yieldToEventLoop?: () => Promise<void>;
}

export interface SearchIndexBackgroundSyncResult extends SearchIndexSyncResult {
  cancelled: boolean;
  sessionsChecked: number;
  maxBatchMs: number;
}

// ---------------------------------------------------------------------------
// Content extraction
// ---------------------------------------------------------------------------

const DEFAULT_BACKGROUND_SYNC_BUDGET_MS = 8;
/** FTS5 merge pages per step. 200 pages took up to 44 ms on an 11k-session index; 32 stays near the budget. */
const FTS_MERGE_PAGES_PER_STEP = 32;
const DEFAULT_BACKGROUND_SYNC_BATCH_SIZE = Number.MAX_SAFE_INTEGER;

function yieldToEventLoop(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

function emptySyncResult(): SearchIndexSyncResult {
  return {
    reindexed: 0,
    added: 0,
    removed: 0,
    skipped: 0,
    transcriptsRead: 0,
    transcriptBytesRead: 0,
    reusedIndexedTranscript: 0,
    transcriptsReindexed: 0,
  };
}

function mergeSyncResults(target: SearchIndexSyncResult, source: SearchIndexSyncResult): void {
  target.reindexed += source.reindexed;
  target.added += source.added;
  target.removed += source.removed;
  target.skipped += source.skipped;
  target.transcriptsRead += source.transcriptsRead;
  target.transcriptBytesRead += source.transcriptBytesRead;
  target.reusedIndexedTranscript += source.reusedIndexedTranscript;
  target.transcriptsReindexed += source.transcriptsReindexed;
}

const log = createLogger({ base: { component: "search_index" } });

interface TranscriptContent {
  userMessages: string;
  assistantMessages: string;
  toolNames: string;
  bytesRead: number;
}

interface ExtractedContent {
  title: string;
  userMessages: string;
  assistantMessages: string;
  toolNames: string;
  transcriptBytesRead: number;
  transcriptRead: boolean;
}

function extractSessionTitle(session: Session): string {
  return [session.name, session.firstMessage]
    .filter((value): value is string => typeof value === "string" && value.trim().length > 0)
    .join(" ")
    .slice(0, 500);
}

function extractTranscriptContent(jsonlPath: string): TranscriptContent | null {
  let bytesRead: number;
  try {
    bytesRead = statSync(jsonlPath).size;
  } catch {
    return null;
  }

  const transcript = extractSearchTranscriptFromFile(jsonlPath);
  if (!transcript) return null;

  return {
    ...transcript,
    bytesRead,
  };
}

function extractIndexedContent(session: Session, jsonlPath?: string): ExtractedContent {
  const transcript = jsonlPath ? extractTranscriptContent(jsonlPath) : null;

  return {
    title: extractSessionTitle(session),
    userMessages: transcript?.userMessages ?? "",
    assistantMessages: transcript?.assistantMessages ?? "",
    toolNames: transcript?.toolNames ?? "",
    transcriptBytesRead: transcript?.bytesRead ?? 0,
    transcriptRead: transcript !== null,
  };
}

// ---------------------------------------------------------------------------
// FTS5 query sanitization
// ---------------------------------------------------------------------------

/** Characters that break FTS5 syntax. */
const FTS5_SPECIAL = /[{}[\]():^]/g;

function sanitizeFtsSegment(raw: string): string {
  return raw.replace(FTS5_SPECIAL, " ").replace(/\s+/g, " ").trim();
}

/**
 * Sanitize a user query for FTS5 MATCH.
 * - Preserves quoted phrases.
 * - Supports explicit uppercase OR operators.
 * - Wraps terms/phrases in quotes for safety.
 */
function sanitizeFtsQuery(raw: string): string {
  const tokens: string[] = [];
  let current = "";
  let inQuote = false;

  const pushCurrent = (): void => {
    const value = sanitizeFtsSegment(current);
    current = "";
    if (!value) return;

    if (inQuote) {
      tokens.push(`"${value}"`);
      return;
    }

    for (const part of value.split(/\s+/).filter(Boolean)) {
      if (part.toUpperCase() === "OR") {
        if (tokens.length > 0 && tokens[tokens.length - 1] !== "OR") {
          tokens.push("OR");
        }
      } else {
        tokens.push(`"${part}"`);
      }
    }
  };

  for (const char of raw) {
    if (char === '"') {
      pushCurrent();
      inQuote = !inQuote;
      continue;
    }
    current += char;
  }
  pushCurrent();

  // Trim dangling OR to avoid invalid MATCH syntax.
  while (tokens[tokens.length - 1] === "OR") {
    tokens.pop();
  }

  return tokens.join(" ");
}

function parseReindexDebounceMs(): number {
  const fallbackMs = 500;
  const raw = process.env.OPPI_SEARCH_REINDEX_DEBOUNCE_MS;
  if (!raw) return fallbackMs;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isInteger(parsed) || parsed <= 0) return fallbackMs;
  return parsed;
}

function finiteTimestampOrNull(value: number | undefined): number | null {
  if (value === undefined || !Number.isFinite(value)) return null;
  return Math.floor(value);
}

// ---------------------------------------------------------------------------
// SearchIndex
// ---------------------------------------------------------------------------

export class SearchIndex {
  private db: SqliteDatabase;
  private pendingReindex = new Set<string>();
  private reindexTimer: ReturnType<typeof setTimeout> | null = null;
  private static readonly REINDEX_DEBOUNCE_MS = parseReindexDebounceMs();

  // Prepared statements (lazy init after ensureSchema)
  private stmtUpsert!: SqliteStatement;
  private stmtUpsertMeta!: SqliteStatement;
  private stmtSearch!: SqliteStatement;
  private stmtRecent!: SqliteStatement;
  private stmtDelete!: SqliteStatement;
  private stmtSetFtsRowid!: SqliteStatement;
  private stmtDeleteMeta!: SqliteStatement;
  private stmtGetMeta!: SqliteStatement;
  private stmtGetIndexedIdentity!: SqliteStatement;
  private stmtGetIndexedRow!: SqliteStatement;
  private stmtGetIndexedIds!: SqliteStatement;

  private getSession: (id: string) => Session | undefined;
  private closed = false;
  private backgroundSyncPromise: Promise<SearchIndexBackgroundSyncResult> | null = null;
  /** Per-session tail of queued durable indexing; see syncDurableSession. */
  private durableTails = new Map<string, Promise<void>>();

  /** Set when the server has a durable Harness. Durable sessions are then indexed from it. */
  durableSource?: DurableSearchSource;
  /**
   * Sessions that bound a durable conversation after a file walk snapshotted
   * them as file-backed. The walk must not write their (nonexistent) JSONL over
   * a durable row, so it hands them to the durable pass instead.
   */
  private lateDurableSessionIds = new Set<string>();

  constructor(dataDir: string, getSession: (id: string) => Session | undefined) {
    this.getSession = getSession;
    const dbPath = join(dataDir, "session-search.db");
    this.db = openDatabase(dbPath);
    // Use exec() for pragmas — bun:sqlite lacks the .pragma() method
    this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec("PRAGMA synchronous = NORMAL");
    this.ensureSchema();
    this.prepareStatements();
    this.migrateToV6();
  }

  // -------------------------------------------------------------------------
  // Schema
  // -------------------------------------------------------------------------

  private ftsMetaColumnNames(): Set<string> {
    const rows = this.db.prepare("PRAGMA table_info(fts_meta)").all() as Array<{ name: string }>;
    return new Set(rows.map((row) => row.name));
  }

  /** v3 → v4: identity columns on fts_meta so skip checks never scan session_fts. */
  private migrateFtsMetaIdentityColumns(): void {
    const columns = this.ftsMetaColumnNames();
    if (!columns.has("workspace_id")) {
      this.db.exec("ALTER TABLE fts_meta ADD COLUMN workspace_id TEXT");
    }
    if (!columns.has("title")) {
      this.db.exec("ALTER TABLE fts_meta ADD COLUMN title TEXT");
    }

    // One FTS scan, then PK updates. Do not look up session_fts per row.
    const identities = this.db
      .prepare("SELECT session_id, workspace_id, title FROM session_fts")
      .all() as Array<{
      session_id: string;
      workspace_id: string;
      title: string;
    }>;
    const update = this.db.prepare(
      "UPDATE fts_meta SET workspace_id = ?, title = ? WHERE session_id = ?",
    );
    const txn = this.db.transaction(() => {
      for (const row of identities) {
        update.run(row.workspace_id, row.title, row.session_id);
      }
    });
    txn();
  }

  /** v4 → v5: durable freshness marker. Existing rows carry NULL, so durable rows rebuild once. */
  private migrateDurableMarkerColumn(): void {
    if (!this.ftsMetaColumnNames().has("durable_marker")) {
      this.db.exec("ALTER TABLE fts_meta ADD COLUMN durable_marker TEXT");
    }
    this.db.prepare("INSERT OR REPLACE INTO fts_schema VALUES ('version', ?)").run("5");
  }

  private schemaVersion(): string | undefined {
    const row = this.db.prepare("SELECT value FROM fts_schema WHERE key = 'version'").get() as
      { value: string } | undefined;
    return row?.value;
  }

  /** v5 shape → v6 shape: fts_meta.fts_rowid; migrateToV6 backfills it. */
  private addFtsRowidColumn(): void {
    if (!this.ftsMetaColumnNames().has("fts_rowid")) {
      this.db.exec("ALTER TABLE fts_meta ADD COLUMN fts_rowid INTEGER");
    }
  }

  /**
   * v5 → v6, after statements exist:
   * - Backfill fts_meta.fts_rowid in one FTS scan and drop FTS rows without
   *   metadata. FTS5 cannot index session_id, so every lookup by it scanned the
   *   whole content table (~30 ms per reindex at 11k sessions).
   * - Inline base64 media is no longer indexed. Rows that hold it go back
   *   through extraction rather than being stripped in place: the media spent
   *   the field caps, so the text it displaced only returns from the source.
   *   Clearing the file fingerprint and durable marker makes the next
   *   (cooperative, background) sync re-extract them once.
   */
  private migrateToV6(): void {
    if (this.schemaVersion() !== "5") return;
    const started = performance.now();
    const ftsRows = this.db.prepare("SELECT rowid, session_id FROM session_fts").all() as Array<{
      rowid: number;
      session_id: string;
    }>;
    const metaIds = new Set(
      (this.stmtGetIndexedIds.all() as Array<{ session_id: string }>).map((row) => row.session_id),
    );
    const setRowid = this.db.prepare("UPDATE fts_meta SET fts_rowid = ? WHERE session_id = ?");
    const deleteByRowid = this.db.prepare("DELETE FROM session_fts WHERE rowid = ?");
    let orphans = 0;
    this.db.transaction(() => {
      for (const row of ftsRows) {
        if (metaIds.has(row.session_id)) {
          setRowid.run(row.rowid, row.session_id);
        } else {
          deleteByRowid.run(row.rowid);
          orphans++;
        }
      }
    })();

    // Index lookup, not a content scan. Prose that says "base64" also matches;
    // re-extracting those few rows is harmless.
    const rows = this.db
      .prepare(
        "SELECT session_id FROM session_fts WHERE session_fts MATCH '{user_messages assistant_messages}: base64'",
      )
      .all() as Array<{ session_id: string }>;
    const invalidate = this.db.prepare(
      "UPDATE fts_meta SET jsonl_mtime_ms = -1, durable_marker = NULL WHERE session_id = ?",
    );
    this.db.transaction(() => {
      for (const row of rows) invalidate.run(row.session_id);
      this.db.prepare("INSERT OR REPLACE INTO fts_schema VALUES ('version', ?)").run("6");
    })();
    log.info("search_index.migrated_v6", {
      rows: ftsRows.length,
      orphans,
      inlineMediaRows: rows.length,
      elapsedMs: Math.round(performance.now() - started),
    });
  }

  private ensureSchema(): void {
    // Check schema version
    const hasSchemaTable = this.db
      .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='fts_schema'")
      .get();

    if (hasSchemaTable) {
      // v3–v5 upgrade in place to the v6 shape; migrateToV6 finishes the data.
      const version = this.schemaVersion();
      if (version === "6") return;
      if (version === "5") {
        if (!this.ftsMetaColumnNames().has("durable_marker")) this.migrateDurableMarkerColumn();
        this.addFtsRowidColumn();
        return;
      }
      if (version === "4" || version === "3") {
        const columns = this.ftsMetaColumnNames();
        if (version === "3" || !columns.has("workspace_id") || !columns.has("title")) {
          this.migrateFtsMetaIdentityColumns();
        }
        this.migrateDurableMarkerColumn();
        this.addFtsRowidColumn();
        return;
      }

      // Unknown/older versions — drop and recreate at v6.
      this.db.exec("DROP TABLE IF EXISTS session_fts");
      this.db.exec("DROP TABLE IF EXISTS fts_meta");
      this.db.exec("DROP TABLE IF EXISTS fts_schema");
    }

    this.db.exec(`
      CREATE VIRTUAL TABLE IF NOT EXISTS session_fts USING fts5(
        session_id UNINDEXED,
        workspace_id UNINDEXED,
        title,
        user_messages,
        assistant_messages,
        tool_names,
        tokenize='porter unicode61'
      );

      CREATE TABLE IF NOT EXISTS fts_meta (
        session_id TEXT PRIMARY KEY,
        jsonl_path TEXT,
        jsonl_mtime_ms INTEGER,
        jsonl_size INTEGER,
        indexed_at INTEGER,
        workspace_id TEXT,
        title TEXT,
        durable_marker TEXT,
        fts_rowid INTEGER
      );

      CREATE TABLE IF NOT EXISTS fts_schema (
        key TEXT PRIMARY KEY,
        value TEXT
      );

      INSERT OR REPLACE INTO fts_schema VALUES ('version', '6');
    `);
  }

  private prepareStatements(): void {
    // FTS rows are addressed through fts_meta.fts_rowid: session_id is UNINDEXED,
    // so `WHERE session_id = ?` on session_fts scans every row.
    // Upsert into FTS: delete old row then insert new (FTS5 has no UPDATE).
    // The session_id check keeps a stale pointer from touching another session's row.
    this.stmtDelete = this.db.prepare(
      "DELETE FROM session_fts WHERE rowid = (SELECT fts_rowid FROM fts_meta WHERE session_id = ?1) AND session_id = ?1",
    );
    this.stmtDeleteMeta = this.db.prepare("DELETE FROM fts_meta WHERE session_id = ?");
    // Runs right after stmtUpsert, so last_insert_rowid() is the new FTS row.
    this.stmtSetFtsRowid = this.db.prepare(`
      INSERT INTO fts_meta (session_id, fts_rowid) VALUES (?, last_insert_rowid())
      ON CONFLICT(session_id) DO UPDATE SET fts_rowid = excluded.fts_rowid
    `);

    this.stmtUpsert = this.db.prepare(`
      INSERT INTO session_fts (
        session_id,
        workspace_id,
        title,
        user_messages,
        assistant_messages,
        tool_names
      )
      VALUES (?, ?, ?, ?, ?, ?)
    `);

    // Upsert, not REPLACE: REPLACE would drop the fts_rowid set by upsertRow.
    this.stmtUpsertMeta = this.db.prepare(`
      INSERT INTO fts_meta (
        session_id,
        jsonl_path,
        jsonl_mtime_ms,
        jsonl_size,
        indexed_at,
        workspace_id,
        title,
        durable_marker
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(session_id) DO UPDATE SET
        jsonl_path = excluded.jsonl_path,
        jsonl_mtime_ms = excluded.jsonl_mtime_ms,
        jsonl_size = excluded.jsonl_size,
        indexed_at = excluded.indexed_at,
        workspace_id = excluded.workspace_id,
        title = excluded.title,
        durable_marker = excluded.durable_marker
    `);

    this.stmtGetMeta = this.db.prepare(
      "SELECT jsonl_path, jsonl_mtime_ms, jsonl_size, workspace_id, title, durable_marker FROM fts_meta WHERE session_id = ?",
    );

    // Skip checks only need identity fields. Avoid pulling transcript blobs on
    // the unchanged-session path that dominates restart warming.
    this.stmtGetIndexedIdentity = this.db.prepare(
      "SELECT workspace_id, title FROM session_fts WHERE rowid = (SELECT fts_rowid FROM fts_meta WHERE session_id = ?1) AND session_id = ?1",
    );

    this.stmtGetIndexedRow = this.db.prepare(
      "SELECT workspace_id, title, user_messages, assistant_messages, tool_names FROM session_fts WHERE rowid = (SELECT fts_rowid FROM fts_meta WHERE session_id = ?1) AND session_id = ?1",
    );
    this.stmtGetIndexedIds = this.db.prepare("SELECT session_id FROM fts_meta");

    // Query search. Column weights: title=10, user_messages=5, assistant_messages=1,
    // tool_names=2. Add a small age penalty so newer sessions rank higher when
    // text relevance is similar. Optional filters constrain workspace and trace mtime.
    this.stmtSearch = this.db.prepare(`
      SELECT
        session_fts.session_id AS sessionId,
        session_fts.workspace_id AS workspaceId,
        session_fts.title AS title,
        COALESCE(
          NULLIF(snippet(session_fts, 3, '<b>', '</b>', '...', 40), ''),
          NULLIF(snippet(session_fts, 4, '<b>', '</b>', '...', 40), ''),
          NULLIF(snippet(session_fts, 5, '<b>', '</b>', '...', 40), ''),
          snippet(session_fts, 2, '<b>', '</b>', '...', 40)
        ) as snippet,
        (
          bm25(session_fts, 0.0, 0.0, 10.0, 5.0, 1.0, 2.0) +
          (((CAST(strftime('%s', 'now') AS REAL) * 1000) - COALESCE(m.jsonl_mtime_ms, 0)) / 86400000.0) * 0.02
        ) as rank,
        m.jsonl_mtime_ms AS updatedAtMs
      FROM session_fts
      JOIN fts_meta m ON m.session_id = session_fts.session_id
      WHERE session_fts MATCH ?
        AND (? IS NULL OR session_fts.workspace_id = ?)
        AND (? IS NULL OR m.jsonl_mtime_ms >= ?)
        AND (? IS NULL OR m.jsonl_mtime_ms <= ?)
      ORDER BY rank ASC, m.jsonl_mtime_ms DESC
      LIMIT ?
    `);

    this.stmtRecent = this.db.prepare(`
      SELECT
        session_fts.session_id AS sessionId,
        session_fts.workspace_id AS workspaceId,
        session_fts.title AS title,
        session_fts.title AS snippet,
        0.0 AS rank,
        m.jsonl_mtime_ms AS updatedAtMs
      FROM session_fts
      JOIN fts_meta m ON m.session_id = session_fts.session_id
      WHERE (? IS NULL OR session_fts.workspace_id = ?)
        AND (? IS NULL OR m.jsonl_mtime_ms >= ?)
        AND (? IS NULL OR m.jsonl_mtime_ms <= ?)
      ORDER BY m.jsonl_mtime_ms DESC
      LIMIT ?
    `);
  }

  // -------------------------------------------------------------------------
  // Search
  // -------------------------------------------------------------------------

  search(
    query: string,
    workspaceId?: string,
    limit = 20,
    filters: SearchFilters = {},
  ): SearchResult[] {
    const ftsQuery = sanitizeFtsQuery(query);
    const cap = Math.min(Math.max(limit, 1), 100);
    const workspaceFilter = workspaceId?.trim() || null;
    const sinceMs = finiteTimestampOrNull(filters.sinceMs);
    const untilMs = finiteTimestampOrNull(filters.untilMs);

    if (!ftsQuery) {
      if (sinceMs === null && untilMs === null) return [];
      return this.stmtRecent.all(
        workspaceFilter,
        workspaceFilter,
        sinceMs,
        sinceMs,
        untilMs,
        untilMs,
        cap,
      ) as SearchResult[];
    }

    try {
      return this.stmtSearch.all(
        ftsQuery,
        workspaceFilter,
        workspaceFilter,
        sinceMs,
        sinceMs,
        untilMs,
        untilMs,
        cap,
      ) as SearchResult[];
    } catch (err) {
      // FTS5 query syntax errors — return empty rather than crash
      log.error("search_index.query.failed", {
        error: (err as Error).message,
      });
      return [];
    }
  }

  // -------------------------------------------------------------------------
  // Indexing
  // -------------------------------------------------------------------------

  /**
   * Index a single session from its JSONL file. Server-durable sessions have no
   * file: their (async) indexing is queued and this returns before it completes.
   */
  indexSession(sessionId: string): void {
    const live = this.getSession(sessionId);
    if (live && this.isIndexedFromDurable(live)) {
      this.queueDurableIndex(sessionId);
      return;
    }
    this.db.transaction(() => {
      const session = this.getSession(sessionId);
      if (!session) return;

      if (session.ephemeral) {
        this.deleteSession(sessionId);
        return;
      }

      const jsonlPath = (session as unknown as Record<string, unknown>).piSessionFile as
        string | undefined;

      let fileStat: { mtimeMs: number; size: number } | null = null;
      if (jsonlPath) {
        try {
          const st = statSync(jsonlPath);
          fileStat = { mtimeMs: st.mtimeMs, size: st.size };
        } catch {
          fileStat = null;
        }
      }

      const content = extractIndexedContent(session, fileStat ? jsonlPath : undefined);

      this.upsertRow(
        sessionId,
        session.workspaceId ?? "",
        content.title,
        content.userMessages,
        content.assistantMessages,
        content.toolNames,
      );

      this.upsertMeta(
        sessionId,
        fileStat ? (jsonlPath ?? null) : null,
        fileStat ? Math.floor(fileStat.mtimeMs) : 0,
        fileStat?.size ?? 0,
        session.workspaceId ?? "",
        content.title,
      );
    })();
  }

  private upsertMeta(
    sessionId: string,
    jsonlPath: string | null,
    jsonlMtimeMs: number,
    jsonlSize: number,
    workspaceId: string,
    title: string,
    durableMarker: string | null = null,
  ): void {
    this.stmtUpsertMeta.run(
      sessionId,
      jsonlPath,
      jsonlMtimeMs,
      jsonlSize,
      Date.now(),
      workspaceId,
      title,
      durableMarker,
    );
  }

  private upsertRow(
    sessionId: string,
    workspaceId: string,
    title: string,
    userMessages: string,
    assistantMessages: string,
    toolNames: string,
  ): void {
    this.stmtDelete.run(sessionId);
    this.stmtUpsert.run(sessionId, workspaceId, title, userMessages, assistantMessages, toolNames);
    this.stmtSetFtsRowid.run(sessionId);
  }

  /** Remove a session from the index. */
  deleteSession(sessionId: string): void {
    this.stmtDelete.run(sessionId);
    this.stmtDeleteMeta.run(sessionId);
  }

  /** Delete a missing/ephemeral session's rows and report whether any existed. */
  private removeIndexedSession(sessionId: string): SearchIndexSyncResult {
    const result = emptySyncResult();
    const wasIndexed =
      this.stmtGetMeta.get(sessionId) !== undefined ||
      this.stmtGetIndexedIdentity.get(sessionId) !== undefined;
    this.deleteSession(sessionId);
    if (wasIndexed) result.removed = 1;
    return result;
  }

  // -------------------------------------------------------------------------
  // Server-durable sessions (async; content comes from the Harness)
  // -------------------------------------------------------------------------

  private isIndexedFromDurable(session: Session): boolean {
    return (
      this.durableSource !== undefined &&
      isServerDurableSession(session) &&
      session.serverDurable?.conversationId !== undefined
    );
  }

  private queueDurableIndex(sessionId: string): void {
    this.syncDurableSession(sessionId).catch((err: unknown) => {
      log.error("search_index.durable_index.failed", {
        sessionId,
        error: err instanceof Error ? err.message : String(err),
      });
    });
  }

  /**
   * Index one durable session: skip when the conversation's newest entry id,
   * title, and workspace are unchanged; otherwise re-extract from the Harness.
   * Runs are serialized per session so an agent_end flush and startup warming
   * cannot write an older read over a newer one.
   */
  syncDurableSession(sessionId: string): Promise<SearchIndexSyncResult> {
    const previous = this.durableTails.get(sessionId) ?? Promise.resolve();
    const run = previous.then(() => this.runDurableSync(sessionId));
    const tail = run.then(
      () => undefined,
      () => undefined,
    );
    this.durableTails.set(sessionId, tail);
    void tail.then(() => {
      if (this.durableTails.get(sessionId) === tail) this.durableTails.delete(sessionId);
    });
    return run;
  }

  /** Live session still bound to this conversation, or undefined after an await invalidated it. */
  private liveDurableSession(sessionId: string, conversationId: number): Session | undefined {
    const live = this.getSession(sessionId);
    if (!live || live.ephemeral || live.serverDurable?.conversationId !== conversationId) {
      return undefined;
    }
    return live;
  }

  private async runDurableSync(sessionId: string): Promise<SearchIndexSyncResult> {
    const result = emptySyncResult();
    const source = this.durableSource;
    const initial = this.getSession(sessionId);
    if (this.closed || !source) return result;
    if (!initial || initial.ephemeral) return this.removeIndexedSession(sessionId);
    const conversationId = initial.serverDurable?.conversationId;
    if (!this.isIndexedFromDurable(initial) || conversationId === undefined) return result;

    // Read the tip before the transcript: content may be newer than the stored
    // marker (one harmless extra reindex), never older.
    const marker = `${conversationId}:${await source.readTipEntryId(conversationId)}`;
    let live = this.liveDurableSession(sessionId, conversationId);
    if (this.closed || !live) return result;

    const workspaceId = live.workspaceId ?? "";
    const title = extractSessionTitle(live);
    const meta = this.stmtGetMeta.get(sessionId) as
      | { workspace_id: string | null; title: string | null; durable_marker: string | null }
      | undefined;
    if (meta?.durable_marker === marker) {
      const indexedRow = this.stmtGetIndexedRow.get(sessionId) as
        { user_messages: string; assistant_messages: string; tool_names: string } | undefined;
      if (indexedRow) {
        if (meta.workspace_id === workspaceId && meta.title === title) {
          result.skipped = 1;
          return result;
        }
        this.writeDurableRow(live, marker, title, indexedRow);
        result.reindexed = 1;
        result.reusedIndexedTranscript = 1;
        return result;
      }
    }

    const transcript = await source.readTranscript(conversationId);
    live = this.liveDurableSession(sessionId, conversationId);
    if (this.closed || !live) return result;
    this.writeDurableRow(live, marker, extractSessionTitle(live), {
      user_messages: transcript.userMessages,
      assistant_messages: transcript.assistantMessages,
      tool_names: transcript.toolNames,
    });
    result.transcriptsRead = 1;
    result.transcriptsReindexed = 1;
    if (meta) result.reindexed = 1;
    else result.added = 1;
    return result;
  }

  /** Durable rows have no file, so recency comes from session activity. */
  private writeDurableRow(
    session: Session,
    marker: string,
    title: string,
    content: { user_messages: string; assistant_messages: string; tool_names: string },
  ): void {
    const workspaceId = session.workspaceId ?? "";
    this.db.transaction(() => {
      this.upsertRow(
        session.id,
        workspaceId,
        title,
        content.user_messages,
        content.assistant_messages,
        content.tool_names,
      );
      this.upsertMeta(
        session.id,
        null,
        Math.floor(Number.isFinite(session.lastActivity) ? session.lastActivity : Date.now()),
        0,
        workspaceId,
        title,
        marker,
      );
    })();
  }

  // -------------------------------------------------------------------------
  // Debounced re-index (live sessions)
  // -------------------------------------------------------------------------

  /** Mark a session for re-indexing. Debounced to avoid thrashing. */
  markForReindex(sessionId: string): void {
    if (this.closed) return;
    this.pendingReindex.add(sessionId);
    if (this.reindexTimer) return;
    this.reindexTimer = setTimeout(() => this.flushPending(), SearchIndex.REINDEX_DEBOUNCE_MS);
  }

  /** Force-flush a specific session's pending re-index (called on agent_end). */
  flushForSession(sessionId: string): void {
    if (!this.pendingReindex.has(sessionId)) return;
    this.pendingReindex.delete(sessionId);
    this.indexSession(sessionId);
  }

  private flushPending(): void {
    this.reindexTimer = null;
    const batch = [...this.pendingReindex];
    this.pendingReindex.clear();

    for (const id of batch) {
      this.indexSession(id);
    }

    if (batch.length > 0) {
      log.info("search_index.reindexed_batch", { count: batch.length });
    }
  }

  // -------------------------------------------------------------------------
  // Startup sync
  // -------------------------------------------------------------------------

  private readTranscriptFingerprint(liveSession: Session): {
    jsonlPath: string | undefined;
    fileStat: { mtimeMs: number; size: number } | null;
    jsonlMtimeMs: number;
    jsonlSize: number;
    expectedJsonlPath: string | null;
  } {
    const jsonlPath = liveSession.piSessionFile;
    let fileStat: { mtimeMs: number; size: number } | null = null;
    if (jsonlPath) {
      try {
        const st = statSync(jsonlPath);
        fileStat = { mtimeMs: st.mtimeMs, size: st.size };
      } catch {
        fileStat = null;
      }
    }
    return {
      jsonlPath,
      fileStat,
      jsonlMtimeMs: fileStat ? Math.floor(fileStat.mtimeMs) : 0,
      jsonlSize: fileStat?.size ?? 0,
      expectedJsonlPath: fileStat ? (jsonlPath ?? null) : null,
    };
  }

  private isUnchangedIndexedSession(liveSession: Session): boolean {
    const fingerprint = this.readTranscriptFingerprint(liveSession);
    const meta = this.stmtGetMeta.get(liveSession.id) as
      | {
          jsonl_path: string | null;
          jsonl_mtime_ms: number;
          jsonl_size: number;
          workspace_id: string | null;
          title: string | null;
        }
      | undefined;
    if (
      !meta ||
      meta.jsonl_mtime_ms !== fingerprint.jsonlMtimeMs ||
      meta.jsonl_size !== fingerprint.jsonlSize ||
      meta.jsonl_path !== fingerprint.expectedJsonlPath
    ) {
      return false;
    }

    const title = extractSessionTitle(liveSession);
    const workspaceId = liveSession.workspaceId ?? "";
    return meta.workspace_id === workspaceId && meta.title === title;
  }

  /**
   * Sessions whose FTS row is the one fts_meta points at. FTS rows nothing points
   * at (an interrupted pair) are deleted here, because rowid-keyed upserts would
   * otherwise leave them behind as duplicates. One FTS scan reads only session_id.
   */
  private loadFtsSessionIds(): Set<string> {
    const pointers = new Map(
      (
        this.db
          .prepare("SELECT session_id, fts_rowid FROM fts_meta WHERE fts_rowid IS NOT NULL")
          .all() as Array<{ session_id: string; fts_rowid: number }>
      ).map((row) => [row.session_id, row.fts_rowid]),
    );
    const rows = this.db.prepare("SELECT rowid, session_id FROM session_fts").all() as Array<{
      rowid: number;
      session_id: string;
    }>;
    const indexed = new Set<string>();
    const stray: number[] = [];
    for (const row of rows) {
      if (pointers.get(row.session_id) === row.rowid) indexed.add(row.session_id);
      else stray.push(row.rowid);
    }
    if (stray.length > 0) {
      const deleteByRowid = this.db.prepare("DELETE FROM session_fts WHERE rowid = ?");
      this.db.transaction(() => {
        for (const rowid of stray) deleteByRowid.run(rowid);
      })();
      log.warn("search_index.stray_rows_removed", { count: stray.length });
    }
    return indexed;
  }

  /** Read-only skip for unchanged sessions. Null means the caller must write. */
  private trySkipUnchangedSession(
    session: Session,
    ftsIds: ReadonlySet<string>,
  ): SearchIndexSyncResult | null {
    if (!ftsIds.has(session.id)) return null;
    const liveSession = this.getSession(session.id);
    if (!liveSession || liveSession.ephemeral) return null;
    // Durable freshness is not file-based; syncSession defers it to the durable pass.
    if (this.isIndexedFromDurable(liveSession)) return null;
    if (!this.isUnchangedIndexedSession(liveSession)) return null;
    const result = emptySyncResult();
    result.skipped = 1;
    return result;
  }

  private syncSession(session: Session, ftsIds: ReadonlySet<string>): SearchIndexSyncResult {
    const result = emptySyncResult();
    // Resolve the startup snapshot ID against live storage immediately before
    // reading indexed fields. Lifecycle can replace or delete this session while
    // cooperative warming is between event-loop turns.
    const liveSession = this.getSession(session.id);
    if (!liveSession || liveSession.ephemeral) {
      return this.removeIndexedSession(session.id);
    }
    if (this.isIndexedFromDurable(liveSession)) {
      this.lateDurableSessionIds.add(liveSession.id);
      return result;
    }

    const sessionId = liveSession.id;
    const fingerprint = this.readTranscriptFingerprint(liveSession);
    const { jsonlPath, fileStat, jsonlMtimeMs, jsonlSize, expectedJsonlPath } = fingerprint;
    const workspaceId = liveSession.workspaceId ?? "";
    const title = extractSessionTitle(liveSession);

    const meta = this.stmtGetMeta.get(sessionId) as
      | {
          jsonl_path: string | null;
          jsonl_mtime_ms: number;
          jsonl_size: number;
          workspace_id: string | null;
          title: string | null;
        }
      | undefined;

    const sameTranscriptState =
      !!meta &&
      meta.jsonl_mtime_ms === jsonlMtimeMs &&
      meta.jsonl_size === jsonlSize &&
      meta.jsonl_path === expectedJsonlPath;

    const sameIndexedMetadata = !!meta && meta.workspace_id === workspaceId && meta.title === title;

    if (sameTranscriptState && sameIndexedMetadata && ftsIds.has(sessionId)) {
      result.skipped = 1;
      return result;
    }

    if (sameTranscriptState) {
      const indexedRow = this.stmtGetIndexedRow.get(sessionId) as
        | {
            workspace_id: string;
            title: string;
            user_messages: string;
            assistant_messages: string;
            tool_names: string;
          }
        | undefined;
      if (!indexedRow) {
        // Fall through to a full reindex when identity exists without content.
      } else {
        this.upsertRow(
          sessionId,
          workspaceId,
          title,
          indexedRow.user_messages,
          indexedRow.assistant_messages,
          indexedRow.tool_names,
        );
        this.upsertMeta(
          sessionId,
          fileStat ? (jsonlPath ?? null) : null,
          jsonlMtimeMs,
          jsonlSize,
          workspaceId,
          title,
        );
        result.reindexed = 1;
        result.reusedIndexedTranscript = 1;
        return result;
      }
    }

    const content = extractIndexedContent(liveSession, fileStat ? jsonlPath : undefined);
    if (content.transcriptRead) {
      result.transcriptsRead = 1;
      result.transcriptsReindexed = 1;
      result.transcriptBytesRead = content.transcriptBytesRead;
    }

    this.upsertRow(
      sessionId,
      workspaceId,
      content.title,
      content.userMessages,
      content.assistantMessages,
      content.toolNames,
    );
    this.upsertMeta(
      sessionId,
      fileStat ? (jsonlPath ?? null) : null,
      jsonlMtimeMs,
      jsonlSize,
      workspaceId,
      content.title,
    );

    if (meta) {
      result.reindexed = 1;
    } else {
      result.added = 1;
    }

    return result;
  }

  private syncAllSessions(
    indexableSessions: Session[],
    sessionIds: ReadonlySet<string>,
  ): SearchIndexSyncResult {
    const ftsIds = this.loadFtsSessionIds();
    const txn = this.db.transaction(() => {
      const result = emptySyncResult();
      for (const session of indexableSessions) {
        mergeSyncResults(result, this.syncSession(session, ftsIds));
      }

      // Keep blocking sync's full rebuild atomic. Background sync deletes these
      // rows in separate bounded transactions instead.
      const allIndexed = this.stmtGetIndexedIds.all() as { session_id: string }[];
      for (const row of allIndexed) {
        if (!sessionIds.has(row.session_id)) {
          this.stmtDelete.run(row.session_id);
          this.stmtDeleteMeta.run(row.session_id);
          result.removed++;
        }
      }
      return result;
    });

    return txn();
  }

  private findOrphanedSessionIds(sessionIds: ReadonlySet<string>): string[] {
    const allIndexed = this.stmtGetIndexedIds.all() as { session_id: string }[];
    // Snapshot-only orphan detection is wrong under cooperative warming: a session
    // created after listSessions() can be indexed live (agent_end → indexSession)
    // and must not be swept. Still drop rows that are gone from storage or ephemeral.
    return allIndexed
      .filter((row) => {
        if (sessionIds.has(row.session_id)) return false;
        const live = this.getSession(row.session_id);
        return !live || live.ephemeral;
      })
      .map((row) => row.session_id);
  }

  private stillWithinBatchBudget(
    nextIndex: number,
    startIndex: number,
    batchStart: number,
    budgetMs: number,
    batchSize: number,
    length: number,
  ): boolean {
    return (
      nextIndex < length &&
      nextIndex - startIndex < batchSize &&
      (nextIndex === startIndex || performance.now() - batchStart < budgetMs)
    );
  }

  private syncSessionBatchWithinBudget(
    sessions: Session[],
    startIndex: number,
    budgetMs: number,
    batchSize: number,
    ftsIds: ReadonlySet<string>,
  ): { nextIndex: number; result: SearchIndexSyncResult; elapsedMs: number } {
    const batchStart = performance.now();
    let nextIndex = startIndex;
    const result = emptySyncResult();

    // Skip-only sessions are read-only. Do not open a write transaction or pull
    // transcript blobs for the unchanged path that dominates restart warming.
    while (
      this.stillWithinBatchBudget(
        nextIndex,
        startIndex,
        batchStart,
        budgetMs,
        batchSize,
        sessions.length,
      )
    ) {
      const skipped = this.trySkipUnchangedSession(sessions[nextIndex], ftsIds);
      if (!skipped) break;
      mergeSyncResults(result, skipped);
      nextIndex++;
    }

    if (
      this.stillWithinBatchBudget(
        nextIndex,
        startIndex,
        batchStart,
        budgetMs,
        batchSize,
        sessions.length,
      )
    ) {
      const txn = this.db.transaction(() => {
        while (
          this.stillWithinBatchBudget(
            nextIndex,
            startIndex,
            batchStart,
            budgetMs,
            batchSize,
            sessions.length,
          )
        ) {
          mergeSyncResults(result, this.syncSession(sessions[nextIndex], ftsIds));
          nextIndex++;
        }
      });
      txn();
    }

    return { nextIndex, result, elapsedMs: performance.now() - batchStart };
  }

  private deleteOrphanBatchWithinBudget(
    orphanIds: string[],
    startIndex: number,
    budgetMs: number,
    batchSize: number,
  ): { nextIndex: number; result: SearchIndexSyncResult; elapsedMs: number } {
    const batchStart = performance.now();
    let nextIndex = startIndex;
    const txn = this.db.transaction(() => {
      const result = emptySyncResult();
      while (
        nextIndex < orphanIds.length &&
        nextIndex - startIndex < batchSize &&
        (nextIndex === startIndex || performance.now() - batchStart < budgetMs)
      ) {
        const sessionId = orphanIds[nextIndex];
        const liveSession = this.getSession(sessionId);
        if (!liveSession || liveSession.ephemeral) {
          this.stmtDelete.run(sessionId);
          this.stmtDeleteMeta.run(sessionId);
          result.removed++;
        }
        nextIndex++;
      }
      return result;
    });

    const result = txn();
    return { nextIndex, result, elapsedMs: performance.now() - batchStart };
  }

  private completeBackgroundSync(
    startedAt: number,
    result: SearchIndexSyncResult,
    sessionsChecked: number,
    maxBatchMs: number,
    cancelled: boolean,
  ): SearchIndexBackgroundSyncResult {
    const completed: SearchIndexBackgroundSyncResult = {
      ...result,
      cancelled,
      sessionsChecked,
      maxBatchMs: Math.round(maxBatchMs),
    };
    log.info("search_index.sync_complete", {
      mode: "background",
      elapsedMs: Math.round(performance.now() - startedAt),
      sessionsChecked: completed.sessionsChecked,
      maxBatchMs: completed.maxBatchMs,
      cancelled: completed.cancelled,
      added: completed.added,
      reindexed: completed.reindexed,
      removed: completed.removed,
      skipped: completed.skipped,
      transcriptsRead: completed.transcriptsRead,
      transcriptsReindexed: completed.transcriptsReindexed,
      transcriptBytesRead: completed.transcriptBytesRead,
      reusedIndexedTranscript: completed.reusedIndexedTranscript,
    });
    return completed;
  }

  private async runBackgroundSync(
    sessions: Session[],
    options: SearchIndexBackgroundSyncOptions,
  ): Promise<SearchIndexBackgroundSyncResult> {
    const budgetMs = options.budgetMs ?? DEFAULT_BACKGROUND_SYNC_BUDGET_MS;
    const batchSize = options.batchSize ?? DEFAULT_BACKGROUND_SYNC_BATCH_SIZE;
    if (!Number.isFinite(budgetMs) || budgetMs < 0) {
      throw new RangeError("Search index background sync budgetMs must be finite and non-negative");
    }
    if (!Number.isSafeInteger(batchSize) || batchSize < 1) {
      throw new RangeError("Search index background sync batchSize must be a positive integer");
    }

    const startedAt = performance.now();
    const indexableSessions = sessions.filter((s) => !s.ephemeral);
    const sessionIds = new Set(indexableSessions.map((s) => s.id));
    const durableSessions = indexableSessions.filter((s) => this.isIndexedFromDurable(s));
    const fileSessions = indexableSessions.filter((s) => !this.isIndexedFromDurable(s));
    const ftsIds = this.loadFtsSessionIds();
    const yieldBetweenBatches = options.yieldToEventLoop ?? yieldToEventLoop;
    const result = emptySyncResult();
    let sessionsChecked = 0;
    let maxBatchMs = 0;

    log.info("search_index.sync_started", {
      mode: "background",
      sessionsTotal: indexableSessions.length,
      budgetMs,
      batchSize,
    });

    let sessionIndex = 0;
    while (sessionIndex < fileSessions.length) {
      if (this.closed) {
        return this.completeBackgroundSync(startedAt, result, sessionsChecked, maxBatchMs, true);
      }

      const batchStartIndex = sessionIndex;
      const batchResult = this.syncSessionBatchWithinBudget(
        fileSessions,
        sessionIndex,
        budgetMs,
        batchSize,
        ftsIds,
      );
      sessionIndex = batchResult.nextIndex;
      const batchSessionsChecked = sessionIndex - batchStartIndex;
      sessionsChecked += batchSessionsChecked;
      maxBatchMs = Math.max(maxBatchMs, batchResult.elapsedMs);
      mergeSyncResults(result, batchResult.result);

      if (sessionIndex < fileSessions.length) {
        await yieldBetweenBatches();
      }
    }

    // Durable reads are async, so they cannot share the synchronous batch
    // transaction above. Each session writes its own small transaction.
    const snapshotDurableIds = new Set(durableSessions.map((s) => s.id));
    const durableIds = new Set(snapshotDurableIds);
    for (const id of this.lateDurableSessionIds) durableIds.add(id);
    this.lateDurableSessionIds.clear();
    let turnStartedAt = performance.now();
    for (const sessionId of durableIds) {
      if (this.closed) {
        return this.completeBackgroundSync(startedAt, result, sessionsChecked, maxBatchMs, true);
      }
      try {
        mergeSyncResults(result, await this.syncDurableSession(sessionId));
      } catch (err: unknown) {
        log.error("search_index.durable_index.failed", {
          sessionId,
          error: err instanceof Error ? err.message : String(err),
        });
      }
      // Late ids were already counted by the file walk that deferred them.
      if (snapshotDurableIds.has(sessionId)) sessionsChecked++;
      if (performance.now() - turnStartedAt >= budgetMs) {
        await yieldBetweenBatches();
        turnStartedAt = performance.now();
      }
    }

    if (this.closed) {
      return this.completeBackgroundSync(startedAt, result, sessionsChecked, maxBatchMs, true);
    }

    const orphanDiscoveryStartedAt = performance.now();
    const orphanIds = this.findOrphanedSessionIds(sessionIds);
    maxBatchMs = Math.max(maxBatchMs, performance.now() - orphanDiscoveryStartedAt);
    // Keep orphan deletion on a later event-loop turn. Its bounded deletion
    // transaction is included in maxBatchMs below, rather than being appended to
    // the final session-indexing turn.
    if (orphanIds.length > 0) {
      await yieldBetweenBatches();
    }
    let orphanIndex = 0;
    while (orphanIndex < orphanIds.length) {
      if (this.closed) {
        return this.completeBackgroundSync(startedAt, result, sessionsChecked, maxBatchMs, true);
      }

      const batchResult = this.deleteOrphanBatchWithinBudget(
        orphanIds,
        orphanIndex,
        budgetMs,
        batchSize,
      );
      orphanIndex = batchResult.nextIndex;
      maxBatchMs = Math.max(maxBatchMs, batchResult.elapsedMs);
      mergeSyncResults(result, batchResult.result);

      if (orphanIndex < orphanIds.length) {
        await yieldBetweenBatches();
      }
    }

    if (result.added + result.reindexed + result.removed > 0) {
      // Replaced FTS rows leave their old postings in segments until a merge.
      // After a bulk reindex that is most of the index (v6 migration measured
      // 103 MB to 37 MB), so merge in small steps between event-loop turns.
      const mergeStep = this.db.prepare(
        "INSERT INTO session_fts(session_fts, rank) VALUES('merge', ?)",
      );
      // changes() stays 1 for the merge command; the segment writes it does show
      // up in total_changes(), which stops moving once there is nothing to merge.
      const totalChanges = this.db.prepare("SELECT total_changes() AS n");
      const readTotalChanges = (): number => (totalChanges.get() as { n: number }).n;
      for (;;) {
        if (this.closed) {
          return this.completeBackgroundSync(startedAt, result, sessionsChecked, maxBatchMs, true);
        }
        const stepStartedAt = performance.now();
        const before = readTotalChanges();
        mergeStep.run(FTS_MERGE_PAGES_PER_STEP);
        const merged = readTotalChanges() - before >= 2;
        maxBatchMs = Math.max(maxBatchMs, performance.now() - stepStartedAt);
        if (!merged) break;
        await yieldBetweenBatches();
      }
    }

    return this.completeBackgroundSync(startedAt, result, sessionsChecked, maxBatchMs, false);
  }

  /**
   * Synchronize the index with current session data in one atomic transaction.
   * - Re-indexes sessions whose JSONL path/mtime/size changed (not durable sessions; see below)
   * - Re-indexes sessions whose indexed metadata (title/workspace) changed
   * - Indexes new sessions not yet in the index
   * - Removes orphaned index entries for deleted sessions
   */
  sync(sessions: Session[]): SearchIndexSyncResult {
    const start = performance.now();
    const indexableSessions = sessions.filter((s) => !s.ephemeral);
    const sessionIds = new Set(indexableSessions.map((s) => s.id));
    // Durable sessions need async Harness reads; blocking sync leaves their rows
    // to startBackgroundSync and agent_end indexing.
    const result = this.syncAllSessions(
      indexableSessions.filter((s) => !this.isIndexedFromDurable(s)),
      sessionIds,
    );
    this.lateDurableSessionIds.clear();
    const elapsed = performance.now() - start;
    log.info("search_index.sync_complete", {
      mode: "blocking",
      elapsedMs: Math.round(elapsed),
      sessionsChecked: indexableSessions.length,
      maxBatchMs: Math.round(elapsed),
      added: result.added,
      reindexed: result.reindexed,
      removed: result.removed,
      skipped: result.skipped,
      transcriptsRead: result.transcriptsRead,
      transcriptsReindexed: result.transcriptsReindexed,
      transcriptBytesRead: result.transcriptBytesRead,
      reusedIndexedTranscript: result.reusedIndexedTranscript,
    });
    return result;
  }

  /** Start a bounded, cooperative startup sync without blocking later event-loop turns. */
  startBackgroundSync(
    sessions: Session[],
    options: SearchIndexBackgroundSyncOptions = {},
  ): Promise<SearchIndexBackgroundSyncResult> {
    if (this.closed) {
      return Promise.resolve({
        ...emptySyncResult(),
        cancelled: true,
        sessionsChecked: 0,
        maxBatchMs: 0,
      });
    }
    if (this.backgroundSyncPromise) {
      log.warn("search_index.sync_already_running", {
        mode: "background",
        requestedSessions: sessions.length,
      });
      return this.backgroundSyncPromise;
    }

    const promise = this.runBackgroundSync(sessions, options);
    this.backgroundSyncPromise = promise;
    void promise.then(
      () => {
        if (this.backgroundSyncPromise === promise) this.backgroundSyncPromise = null;
      },
      () => {
        if (this.backgroundSyncPromise === promise) this.backgroundSyncPromise = null;
      },
    );
    return promise;
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  close(): void {
    this.closed = true;
    if (this.reindexTimer) {
      clearTimeout(this.reindexTimer);
      this.flushPending();
    }
    this.db.close();
  }
}
