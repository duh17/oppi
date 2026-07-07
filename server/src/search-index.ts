/**
 * SQLite FTS5-backed full-text search index for session content.
 *
 * Indexes user messages, assistant text, tool names, and session title
 * for fast keyword search across all sessions. The index lives in a
 * SQLite database file alongside the session data.
 *
 * Lifecycle:
 * - Server boot: open db, incremental sync (JSONL state + session metadata)
 * - Live: debounced re-index on message_end / agent_end events
 * - Shutdown: close db
 */

import { openDatabase, type SqliteDatabase, type SqliteStatement } from "./sqlite-compat.js";
import { statSync } from "node:fs";
import { join } from "node:path";

import type { Session } from "./types.js";
import { createLogger } from "./logger.js";
import { readSessionTraceFromFile } from "./trace.js";

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

// ---------------------------------------------------------------------------
// Content extraction
// ---------------------------------------------------------------------------

const USER_MESSAGE_CAP = 50_000;
const ASSISTANT_MESSAGE_CAP = 100_000;

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

  const events = readSessionTraceFromFile(jsonlPath);
  if (!events) return null;

  const userParts: string[] = [];
  const assistantParts: string[] = [];
  const toolNameSet = new Set<string>();
  let userLen = 0;
  let assistantLen = 0;

  for (const event of events) {
    if (event.type === "user" && event.text && userLen < USER_MESSAGE_CAP) {
      userParts.push(event.text);
      userLen += event.text.length;
    } else if (event.type === "assistant" && event.text && assistantLen < ASSISTANT_MESSAGE_CAP) {
      assistantParts.push(event.text);
      assistantLen += event.text.length;
    } else if (event.type === "toolCall" && event.tool) {
      toolNameSet.add(event.tool);
    }
  }

  return {
    userMessages: userParts.join("\n").slice(0, USER_MESSAGE_CAP),
    assistantMessages: assistantParts.join("\n").slice(0, ASSISTANT_MESSAGE_CAP),
    toolNames: [...toolNameSet].join(" "),
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
  private stmtDeleteMeta!: SqliteStatement;
  private stmtGetMeta!: SqliteStatement;
  private stmtGetIndexedRow!: SqliteStatement;

  private getSession: (id: string) => Session | undefined;
  private closed = false;

  constructor(dataDir: string, getSession: (id: string) => Session | undefined) {
    this.getSession = getSession;
    const dbPath = join(dataDir, "session-search.db");
    this.db = openDatabase(dbPath);
    // Use exec() for pragmas — bun:sqlite lacks the .pragma() method
    this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec("PRAGMA synchronous = NORMAL");
    this.ensureSchema();
    this.prepareStatements();
  }

  // -------------------------------------------------------------------------
  // Schema
  // -------------------------------------------------------------------------

  private ensureSchema(): void {
    // Check schema version
    const hasSchemaTable = this.db
      .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='fts_schema'")
      .get();

    if (hasSchemaTable) {
      const row = this.db.prepare("SELECT value FROM fts_schema WHERE key = 'version'").get() as
        | { value: string }
        | undefined;
      if (row?.value === "3") return; // Schema up to date

      // Version mismatch — drop and recreate
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
        indexed_at INTEGER
      );

      CREATE TABLE IF NOT EXISTS fts_schema (
        key TEXT PRIMARY KEY,
        value TEXT
      );

      INSERT OR REPLACE INTO fts_schema VALUES ('version', '3');
    `);
  }

  private prepareStatements(): void {
    // Upsert into FTS: delete old row then insert new
    // FTS5 doesn't support UPDATE, so we delete + insert
    this.stmtDelete = this.db.prepare("DELETE FROM session_fts WHERE session_id = ?");
    this.stmtDeleteMeta = this.db.prepare("DELETE FROM fts_meta WHERE session_id = ?");

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

    this.stmtUpsertMeta = this.db.prepare(`
      INSERT OR REPLACE INTO fts_meta (
        session_id,
        jsonl_path,
        jsonl_mtime_ms,
        jsonl_size,
        indexed_at
      )
      VALUES (?, ?, ?, ?, ?)
    `);

    this.stmtGetMeta = this.db.prepare(
      "SELECT jsonl_path, jsonl_mtime_ms, jsonl_size FROM fts_meta WHERE session_id = ?",
    );

    this.stmtGetIndexedRow = this.db.prepare(
      "SELECT workspace_id, title, user_messages, assistant_messages, tool_names FROM session_fts WHERE session_id = ?",
    );

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

  /** Index a single session from its JSONL file. */
  indexSession(sessionId: string): void {
    this.db.transaction(() => {
      const session = this.getSession(sessionId);
      if (!session) return;

      if (session.ephemeral) {
        this.deleteSession(sessionId);
        return;
      }

      const jsonlPath = (session as unknown as Record<string, unknown>).piSessionFile as
        | string
        | undefined;

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

      this.stmtUpsertMeta.run(
        sessionId,
        fileStat ? (jsonlPath ?? null) : null,
        fileStat ? Math.floor(fileStat.mtimeMs) : 0,
        fileStat?.size ?? 0,
        Date.now(),
      );
    })();
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
  }

  /** Remove a session from the index. */
  deleteSession(sessionId: string): void {
    this.stmtDelete.run(sessionId);
    this.stmtDeleteMeta.run(sessionId);
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

  /**
   * Synchronize the index with current session data.
   * - Re-indexes sessions whose JSONL path/mtime/size changed
   * - Re-indexes sessions whose indexed metadata (title/workspace) changed
   * - Indexes new sessions not yet in the index
   * - Removes orphaned index entries for deleted sessions
   */
  sync(sessions: Session[]): {
    reindexed: number;
    added: number;
    removed: number;
    skipped: number;
    transcriptsRead: number;
    transcriptBytesRead: number;
    reusedIndexedTranscript: number;
  } {
    const start = performance.now();
    const indexableSessions = sessions.filter((s) => !s.ephemeral);
    const sessionIds = new Set(indexableSessions.map((s) => s.id));
    let reindexed = 0;
    let added = 0;
    let skipped = 0;
    let transcriptsRead = 0;
    let transcriptBytesRead = 0;
    let reusedIndexedTranscript = 0;

    const txn = this.db.transaction(() => {
      for (const session of indexableSessions) {
        const jsonlPath = (session as unknown as Record<string, unknown>).piSessionFile as
          | string
          | undefined;

        let fileStat: { mtimeMs: number; size: number } | null = null;
        if (jsonlPath) {
          try {
            const st = statSync(jsonlPath);
            fileStat = { mtimeMs: st.mtimeMs, size: st.size };
          } catch {
            fileStat = null;
          }
        }

        // Check if already indexed with same transcript state.
        const meta = this.stmtGetMeta.get(session.id) as
          | {
              jsonl_path: string | null;
              jsonl_mtime_ms: number;
              jsonl_size: number;
            }
          | undefined;

        const indexedRow = this.stmtGetIndexedRow.get(session.id) as
          | {
              workspace_id: string;
              title: string;
              user_messages: string;
              assistant_messages: string;
              tool_names: string;
            }
          | undefined;

        const jsonlMtimeMs = fileStat ? Math.floor(fileStat.mtimeMs) : 0;
        const jsonlSize = fileStat?.size ?? 0;
        const expectedJsonlPath = fileStat ? (jsonlPath ?? null) : null;
        const workspaceId = session.workspaceId ?? "";

        const sameTranscriptState =
          !!meta &&
          meta.jsonl_mtime_ms === jsonlMtimeMs &&
          meta.jsonl_size === jsonlSize &&
          meta.jsonl_path === expectedJsonlPath;

        const title = extractSessionTitle(session);
        const sameIndexedMetadata =
          !!indexedRow && indexedRow.workspace_id === workspaceId && indexedRow.title === title;

        if (sameTranscriptState && sameIndexedMetadata) {
          skipped++;
          continue;
        }

        if (sameTranscriptState && indexedRow) {
          this.upsertRow(
            session.id,
            workspaceId,
            title,
            indexedRow.user_messages,
            indexedRow.assistant_messages,
            indexedRow.tool_names,
          );
          this.stmtUpsertMeta.run(
            session.id,
            fileStat ? (jsonlPath ?? null) : null,
            jsonlMtimeMs,
            jsonlSize,
            Date.now(),
          );
          reindexed++;
          reusedIndexedTranscript++;
          continue;
        }

        const content = extractIndexedContent(session, fileStat ? jsonlPath : undefined);
        if (content.transcriptRead) {
          transcriptsRead++;
          transcriptBytesRead += content.transcriptBytesRead;
        }

        this.upsertRow(
          session.id,
          workspaceId,
          content.title,
          content.userMessages,
          content.assistantMessages,
          content.toolNames,
        );
        this.stmtUpsertMeta.run(
          session.id,
          fileStat ? (jsonlPath ?? null) : null,
          jsonlMtimeMs,
          jsonlSize,
          Date.now(),
        );

        if (meta) {
          reindexed++;
        } else {
          added++;
        }
      }

      // Remove orphaned entries
      const allIndexed = this.db.prepare("SELECT session_id FROM fts_meta").all() as {
        session_id: string;
      }[];

      let removed = 0;
      for (const row of allIndexed) {
        if (!sessionIds.has(row.session_id)) {
          this.stmtDelete.run(row.session_id);
          this.stmtDeleteMeta.run(row.session_id);
          removed++;
        }
      }

      return {
        reindexed,
        added,
        removed,
        skipped,
        transcriptsRead,
        transcriptBytesRead,
        reusedIndexedTranscript,
      };
    });

    const result = txn();
    const elapsed = performance.now() - start;
    log.info("search_index.sync_complete", {
      elapsedMs: Math.round(elapsed),
      added: result.added,
      reindexed: result.reindexed,
      removed: result.removed,
      skipped: result.skipped,
      transcriptsRead: result.transcriptsRead,
      transcriptBytesRead: result.transcriptBytesRead,
      reusedIndexedTranscript: result.reusedIndexedTranscript,
    });
    return result;
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
