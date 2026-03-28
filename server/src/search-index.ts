/**
 * SQLite FTS5-backed full-text search index for session content.
 *
 * Indexes user messages, assistant text, tool names, and session title
 * for fast keyword search across all sessions. The index lives in a
 * SQLite database file alongside the session data.
 *
 * Lifecycle:
 * - Server boot: open db, incremental sync (mtime-based)
 * - Live: debounced re-index on message_end / agent_end events
 * - Shutdown: close db
 */

import { openDatabase, type SqliteDatabase, type SqliteStatement } from "./sqlite-compat.js";
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";

import type { Session } from "./types.js";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface SearchResult {
  sessionId: string;
  workspaceId: string;
  title: string;
  snippet: string;
  rank: number;
}

// ---------------------------------------------------------------------------
// Content extraction
// ---------------------------------------------------------------------------

/** Text block types we extract from message content arrays. */
const TEXT_BLOCK_TYPES = new Set(["text", "output_text"]);

function extractTextFromContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const block of content) {
    if (block && typeof block === "object" && TEXT_BLOCK_TYPES.has(block.type) && block.text) {
      parts.push(block.text);
    }
  }
  return parts.join("\n");
}

function extractToolNames(content: unknown): Set<string> {
  const names = new Set<string>();
  if (!Array.isArray(content)) return names;
  for (const block of content) {
    if (
      block &&
      typeof block === "object" &&
      (block.type === "toolCall" || block.type === "tool_call") &&
      block.name
    ) {
      names.add(block.name);
    }
  }
  return names;
}

const USER_MESSAGE_CAP = 50_000;
const ASSISTANT_MESSAGE_CAP = 100_000;

interface ExtractedContent {
  title: string;
  userMessages: string;
  assistantMessages: string;
  toolNames: string;
}

function extractContentFromJsonl(session: Session, jsonlPath: string): ExtractedContent | null {
  let raw: string;
  try {
    raw = readFileSync(jsonlPath, "utf-8");
  } catch {
    return null;
  }

  const title = [session.name, session.firstMessage].filter(Boolean).join(" ").slice(0, 500);
  const userParts: string[] = [];
  const assistantParts: string[] = [];
  const toolNameSet = new Set<string>();

  let userLen = 0;
  let assistantLen = 0;

  for (const line of raw.split("\n")) {
    if (!line) continue;
    let entry: Record<string, unknown>;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }
    if (entry.type !== "message") continue;
    const msg = entry.message as Record<string, unknown> | undefined;
    if (!msg?.content) continue;

    if (msg.role === "user" && userLen < USER_MESSAGE_CAP) {
      const text = extractTextFromContent(msg.content);
      userParts.push(text);
      userLen += text.length;
    } else if (msg.role === "assistant" && assistantLen < ASSISTANT_MESSAGE_CAP) {
      const text = extractTextFromContent(msg.content);
      assistantParts.push(text);
      assistantLen += text.length;
      for (const name of extractToolNames(msg.content)) {
        toolNameSet.add(name);
      }
    }
  }

  return {
    title,
    userMessages: userParts.join("\n").slice(0, USER_MESSAGE_CAP),
    assistantMessages: assistantParts.join("\n").slice(0, ASSISTANT_MESSAGE_CAP),
    toolNames: [...toolNameSet].join(" "),
  };
}

// ---------------------------------------------------------------------------
// FTS5 query sanitization
// ---------------------------------------------------------------------------

/** Characters that break FTS5 syntax. */
const FTS5_SPECIAL = /[{}[\]():^"]/g;

/**
 * Sanitize a user query for FTS5 MATCH.
 * Strips special chars, wraps each term in quotes for safety.
 */
function sanitizeFtsQuery(raw: string): string {
  const cleaned = raw.replace(FTS5_SPECIAL, " ").trim();
  if (!cleaned) return "";
  const terms = cleaned.split(/\s+/).filter(Boolean);
  if (terms.length === 0) return "";
  // Wrap each term in quotes to avoid syntax errors, join with implicit AND
  return terms.map((t) => `"${t}"`).join(" ");
}

// ---------------------------------------------------------------------------
// SearchIndex
// ---------------------------------------------------------------------------

export class SearchIndex {
  private db: SqliteDatabase;
  private pendingReindex = new Set<string>();
  private reindexTimer: ReturnType<typeof setTimeout> | null = null;
  private static readonly REINDEX_DEBOUNCE_MS = 2000;

  // Prepared statements (lazy init after ensureSchema)
  private stmtUpsert!: SqliteStatement;
  private stmtUpsertMeta!: SqliteStatement;
  private stmtSearch!: SqliteStatement;
  private stmtSearchWorkspace!: SqliteStatement;
  private stmtDelete!: SqliteStatement;
  private stmtDeleteMeta!: SqliteStatement;
  private stmtGetMeta!: SqliteStatement;
  private stmtCount!: SqliteStatement;

  private getSession: (id: string) => Session | undefined;
  private closed = false;

  constructor(dataDir: string, getSession: (id: string) => Session | undefined) {
    this.getSession = getSession;
    const dbPath = join(dataDir, "session-search.db");
    this.db = openDatabase(dbPath);
    // Use exec() for pragmas — works in both better-sqlite3 and bun:sqlite
    // (bun:sqlite lacks the .pragma() method)
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
      if (row?.value === "1") return; // Schema up to date

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

      INSERT OR REPLACE INTO fts_schema VALUES ('version', '1');
    `);
  }

  private prepareStatements(): void {
    // Upsert into FTS: delete old row then insert new
    // FTS5 doesn't support UPDATE, so we delete + insert
    this.stmtDelete = this.db.prepare("DELETE FROM session_fts WHERE session_id = ?");
    this.stmtDeleteMeta = this.db.prepare("DELETE FROM fts_meta WHERE session_id = ?");

    this.stmtUpsert = this.db.prepare(`
      INSERT INTO session_fts (session_id, workspace_id, title, user_messages, assistant_messages, tool_names)
      VALUES (?, ?, ?, ?, ?, ?)
    `);

    this.stmtUpsertMeta = this.db.prepare(`
      INSERT OR REPLACE INTO fts_meta (session_id, jsonl_path, jsonl_mtime_ms, jsonl_size, indexed_at)
      VALUES (?, ?, ?, ?, ?)
    `);

    this.stmtGetMeta = this.db.prepare(
      "SELECT jsonl_mtime_ms, jsonl_size FROM fts_meta WHERE session_id = ?",
    );

    // Search across all workspaces
    // Column weights: title=10, user_messages=5, assistant_messages=1, tool_names=2
    this.stmtSearch = this.db.prepare(`
      SELECT
        session_id,
        workspace_id,
        title,
        COALESCE(
          NULLIF(snippet(session_fts, 3, '<b>', '</b>', '...', 40), ''),
          snippet(session_fts, 4, '<b>', '</b>', '...', 40)
        ) as snippet,
        bm25(session_fts, 0.0, 0.0, 10.0, 5.0, 1.0, 2.0) as rank
      FROM session_fts
      WHERE session_fts MATCH ?
      ORDER BY rank
      LIMIT ?
    `);

    // Search within a specific workspace
    this.stmtSearchWorkspace = this.db.prepare(`
      SELECT
        session_id,
        workspace_id,
        title,
        COALESCE(
          NULLIF(snippet(session_fts, 3, '<b>', '</b>', '...', 40), ''),
          snippet(session_fts, 4, '<b>', '</b>', '...', 40)
        ) as snippet,
        bm25(session_fts, 0.0, 0.0, 10.0, 5.0, 1.0, 2.0) as rank
      FROM session_fts
      WHERE session_fts MATCH ? AND workspace_id = ?
      ORDER BY rank
      LIMIT ?
    `);

    this.stmtCount = this.db.prepare("SELECT count(*) as cnt FROM fts_meta");
  }

  // -------------------------------------------------------------------------
  // Search
  // -------------------------------------------------------------------------

  search(query: string, workspaceId?: string, limit = 20): SearchResult[] {
    const ftsQuery = sanitizeFtsQuery(query);
    if (!ftsQuery) return [];

    const cap = Math.min(Math.max(limit, 1), 100);

    try {
      if (workspaceId) {
        return this.stmtSearchWorkspace.all(ftsQuery, workspaceId, cap) as SearchResult[];
      }
      return this.stmtSearch.all(ftsQuery, cap) as SearchResult[];
    } catch (err) {
      // FTS5 query syntax errors — return empty rather than crash
      console.error("[search-index] query error:", (err as Error).message);
      return [];
    }
  }

  /** Number of indexed sessions. */
  indexedCount(): number {
    const row = this.stmtCount.get() as { cnt: number };
    return row.cnt;
  }

  // -------------------------------------------------------------------------
  // Indexing
  // -------------------------------------------------------------------------

  /** Index a single session from its JSONL file. */
  indexSession(sessionId: string): void {
    this.db.transaction(() => {
      const session = this.getSession(sessionId);
      if (!session) return;

      const jsonlPath = (session as unknown as Record<string, unknown>).piSessionFile as
        | string
        | undefined;
      if (!jsonlPath) {
        // No JSONL yet — index title only
        this.upsertRow(
          sessionId,
          session.workspaceId ?? "",
          session.name ?? session.firstMessage ?? "",
          "",
          "",
          "",
        );
        return;
      }

      let fileStat: { mtimeMs: number; size: number };
      try {
        const st = statSync(jsonlPath);
        fileStat = { mtimeMs: st.mtimeMs, size: st.size };
      } catch {
        // File doesn't exist — index title only
        this.upsertRow(
          sessionId,
          session.workspaceId ?? "",
          session.name ?? session.firstMessage ?? "",
          "",
          "",
          "",
        );
        return;
      }

      const content = extractContentFromJsonl(session, jsonlPath);
      if (!content) return;

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
        jsonlPath,
        Math.floor(fileStat.mtimeMs),
        fileStat.size,
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

    const txn = this.db.transaction(() => {
      for (const id of batch) {
        this.indexSession(id);
      }
    });
    txn();

    if (batch.length > 0) {
      console.log("[search-index] re-indexed", { count: batch.length });
    }
  }

  // -------------------------------------------------------------------------
  // Startup sync
  // -------------------------------------------------------------------------

  /**
   * Synchronize the index with current session data.
   * - Re-indexes sessions whose JSONL mtime/size changed
   * - Indexes new sessions not yet in the index
   * - Removes orphaned index entries for deleted sessions
   */
  sync(sessions: Session[]): {
    reindexed: number;
    added: number;
    removed: number;
    skipped: number;
  } {
    const start = performance.now();
    const sessionIds = new Set(sessions.map((s) => s.id));
    let reindexed = 0;
    let added = 0;
    let skipped = 0;

    const txn = this.db.transaction(() => {
      for (const session of sessions) {
        const jsonlPath = (session as unknown as Record<string, unknown>).piSessionFile as
          | string
          | undefined;

        if (!jsonlPath) {
          // No JSONL — check if already indexed
          const meta = this.stmtGetMeta.get(session.id);
          if (!meta) {
            this.upsertRow(
              session.id,
              session.workspaceId ?? "",
              session.name ?? session.firstMessage ?? "",
              "",
              "",
              "",
            );
            this.stmtUpsertMeta.run(session.id, null, 0, 0, Date.now());
            added++;
          } else {
            skipped++;
          }
          continue;
        }

        let fileStat: { mtimeMs: number; size: number };
        try {
          const st = statSync(jsonlPath);
          fileStat = { mtimeMs: st.mtimeMs, size: st.size };
        } catch {
          skipped++;
          continue;
        }

        // Check if already indexed with same mtime/size
        const meta = this.stmtGetMeta.get(session.id) as
          | { jsonl_mtime_ms: number; jsonl_size: number }
          | undefined;

        if (
          meta &&
          meta.jsonl_mtime_ms === Math.floor(fileStat.mtimeMs) &&
          meta.jsonl_size === fileStat.size
        ) {
          skipped++;
          continue;
        }

        // Need to (re-)index
        const content = extractContentFromJsonl(session, jsonlPath);
        if (!content) {
          skipped++;
          continue;
        }

        this.upsertRow(
          session.id,
          session.workspaceId ?? "",
          content.title,
          content.userMessages,
          content.assistantMessages,
          content.toolNames,
        );
        this.stmtUpsertMeta.run(
          session.id,
          jsonlPath,
          Math.floor(fileStat.mtimeMs),
          fileStat.size,
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

      return { reindexed, added, removed, skipped };
    });

    const result = txn();
    const elapsed = performance.now() - start;
    console.log("[search-index] sync complete", {
      elapsedMs: Math.round(elapsed),
      added: result.added,
      reindexed: result.reindexed,
      removed: result.removed,
      skipped: result.skipped,
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
