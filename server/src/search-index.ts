/**
 * SQLite FTS5-backed full-text search index for session content.
 *
 * Indexes user messages, assistant text, tool names, and session title
 * for fast keyword search across all sessions. The index lives in a
 * SQLite database file alongside the session data.
 *
 * Lifecycle:
 * - Server boot: open db, incremental sync (JSONL state + session metadata)
 * - Live: re-index on agent_end. A file-backed session reads only the bytes
 *   appended since the stored cursor; truncation, rewrite, compaction, or fork
 *   falls back to a full reindex. The read is async and does not block the
 *   event loop on the whole file.
 * - Shutdown: close db
 */

import { createHash } from "node:crypto";
import { closeSync, openSync, readSync, statSync } from "node:fs";
import { open, stat } from "node:fs/promises";
import { join } from "node:path";

import { createLogger } from "./logger.js";
import { isServerDurableSession } from "./session-runtime-capabilities.js";
import { openDatabase, type SqliteDatabase, type SqliteStatement } from "./sqlite-compat.js";
import {
  extractSearchTranscriptFromEntries,
  extractSearchTranscriptFromEntriesYielding,
  parseSessionEntries,
  readSearchTranscriptFile,
  SEARCH_ASSISTANT_MESSAGE_CAP,
  SEARCH_USER_MESSAGE_CAP,
  sessionTranscriptLeafId,
  type SearchTranscriptContent,
  type SessionEntry,
} from "./trace.js";
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
/** Visible entries walked between event-loop yields on a full reindex. */
const FULL_REINDEX_YIELD_EVERY = 1_000;
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
  leafId: string | null;
}

interface ExtractedContent {
  title: string;
  userMessages: string;
  assistantMessages: string;
  toolNames: string;
  transcriptBytesRead: number;
  transcriptRead: boolean;
  leafId: string | null;
}

/** Byte cursor stored on fts_meta so the next turn reads only the append. */
interface FileCursor {
  dev: string;
  ino: string;
  offset: number;
  boundary: string;
  leafId: string;
}

interface FileStat {
  dev: string;
  ino: string;
  size: number;
  mtimeMs: number;
}

interface FtsMetaRow {
  jsonl_path: string | null;
  jsonl_mtime_ms: number;
  jsonl_size: number;
  workspace_id: string | null;
  title: string | null;
  durable_marker: string | null;
  jsonl_dev: string | null;
  jsonl_ino: string | null;
  jsonl_offset: number | null;
  jsonl_boundary: string | null;
  jsonl_leaf_id: string | null;
}

/** Last bytes of the indexed prefix. In-place rewrite keeps the inode, so size and inode alone do not prove the prefix is unchanged. */
const FILE_BOUNDARY_BYTES = 64;
/** Appended entry types that change which earlier lines are visible. */
const FULL_REINDEX_ENTRY_TYPES = new Set(["compaction", "branch_summary", "session"]);

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

  const read = readSearchTranscriptFile(jsonlPath);
  if (!read) return null;

  return {
    ...read.transcript,
    bytesRead,
    leafId: read.leafId,
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
    leafId: transcript?.leafId ?? null,
  };
}

function emptyTranscript(): SearchTranscriptContent {
  return { userMessages: "", assistantMessages: "", toolNames: "" };
}

function fileStatFrom(st: {
  dev: bigint;
  ino: bigint;
  size: bigint;
  mtimeMs: bigint;
}): FileStat | null {
  if (st.size > BigInt(Number.MAX_SAFE_INTEGER)) return null;
  return {
    dev: st.dev.toString(),
    ino: st.ino.toString(),
    size: Number(st.size),
    mtimeMs: Number(st.mtimeMs),
  };
}

function boundaryHash(bytes: Buffer): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function readBoundarySync(path: string, offset: number): string {
  if (offset <= 0) return "";
  return boundaryHash(readByteRangeSync(path, Math.max(0, offset - FILE_BOUNDARY_BYTES), offset));
}

function readByteRangeSync(path: string, start: number, end: number): Buffer {
  const length = end - start;
  if (length <= 0) return Buffer.alloc(0);
  const buffer = Buffer.alloc(length);
  const fd = openSync(path, "r");
  try {
    let offset = 0;
    while (offset < length) {
      const bytesRead = readSync(fd, buffer, offset, length - offset, start + offset);
      if (bytesRead === 0) break;
      offset += bytesRead;
    }
    return offset === length ? buffer : buffer.subarray(0, offset);
  } finally {
    closeSync(fd);
  }
}

/** Incremental merge is only valid when the stored offset is a line boundary. */
function offsetIsLineBoundarySync(path: string, offset: number): boolean {
  if (offset <= 0) return true;
  return readByteRangeSync(path, offset - 1, offset)[0] === 0x0a;
}

/**
 * Leaf id from the end of the file. Used to backfill a cursor without reading
 * a session that is already indexed and unchanged.
 */
function leafIdFromFileTail(path: string, size: number): string {
  if (size <= 0) return "";
  let window = 64 * 1024;
  while (window < size) {
    const start = size - window;
    const text = readByteRangeSync(path, start, size).toString("utf8");
    const newline = text.indexOf("\n");
    if (newline >= 0) {
      const leaf = sessionTranscriptLeafId(parseSessionEntries(text.slice(newline + 1)));
      if (leaf) return leaf;
    }
    window *= 4;
  }
  return (
    sessionTranscriptLeafId(
      parseSessionEntries(readByteRangeSync(path, 0, size).toString("utf8")),
    ) ?? ""
  );
}

async function readByteRange(path: string, start: number, end: number): Promise<Buffer> {
  const length = end - start;
  if (length <= 0) return Buffer.alloc(0);
  const handle = await open(path, "r");
  try {
    const buffer = Buffer.alloc(length);
    let offset = 0;
    while (offset < length) {
      const { bytesRead } = await handle.read(buffer, offset, length - offset, start + offset);
      if (bytesRead === 0) break;
      offset += bytesRead;
    }
    return offset === length ? buffer : buffer.subarray(0, offset);
  } finally {
    await handle.close();
  }
}

async function readBoundary(path: string, offset: number): Promise<string> {
  if (offset <= 0) return "";
  const start = Math.max(0, offset - FILE_BOUNDARY_BYTES);
  return boundaryHash(await readByteRange(path, start, offset));
}

function cursorFromMeta(meta: FtsMetaRow): FileCursor | null {
  const dev = meta.jsonl_dev;
  const ino = meta.jsonl_ino;
  const offset = meta.jsonl_offset;
  const boundary = meta.jsonl_boundary;
  const leafId = meta.jsonl_leaf_id;
  if (dev === null || ino === null || offset === null || boundary === null || leafId === null) {
    return null;
  }
  return {
    dev,
    ino,
    offset,
    boundary,
    leafId,
  };
}

function cursorForFile(stat: FileStat, boundary: string, leafId: string | null): FileCursor {
  return {
    dev: stat.dev,
    ino: stat.ino,
    offset: stat.size,
    boundary,
    leafId: leafId ?? "",
  };
}

/**
 * A snapshot must not overwrite a cursor that already indexed a later prefix of
 * the same file. Truncation and a same-size rewrite make the stored cursor
 * stale: the snapshot is the file, and refusing it would retry forever.
 */
function storedCursorIsNewer(stored: FileCursor, snapshot: FileCursor, fileSize: number): boolean {
  if (stored.dev !== snapshot.dev || stored.ino !== snapshot.ino) return false;
  if (snapshot.offset === fileSize && fileSize <= stored.offset) return false;
  if (stored.offset > snapshot.offset) return true;
  return stored.offset === snapshot.offset && stored.boundary !== snapshot.boundary;
}

function appendCapped(existing: string, addition: string, cap: number): string {
  if (!addition) return existing.length > cap ? existing.slice(0, cap) : existing;
  if (!existing || existing.length >= cap) {
    return existing ? existing.slice(0, cap) : addition.slice(0, cap);
  }
  const joined = `${existing}\n${addition}`;
  return joined.length > cap ? joined.slice(0, cap) : joined;
}

function mergeToolNames(existing: string, addition: string): string {
  if (!addition) return existing;
  if (!existing) return addition;
  const seen = new Set(existing.split(" ").filter(Boolean));
  const extra: string[] = [];
  for (const name of addition.split(" ").filter(Boolean)) {
    if (seen.has(name)) continue;
    seen.add(name);
    extra.push(name);
  }
  return extra.length === 0 ? existing : `${existing} ${extra.join(" ")}`;
}

function tailHasUnsafeToolName(entries: SessionEntry[]): boolean {
  for (const entry of entries) {
    const content = entry.message?.content;
    if (!Array.isArray(content)) continue;
    for (const block of content) {
      if (!block || typeof block !== "object") continue;
      const record = block as { type?: unknown; name?: unknown };
      if (record.type === "toolCall" && typeof record.name === "string" && /\s/.test(record.name)) {
        return true;
      }
    }
  }
  return false;
}

/**
 * True when the appended entries only extend the indexed leaf. Compaction,
 * a new session header, a branch summary, or a fork (parent chain misses the
 * stored leaf) changes visibility of earlier lines, so the caller must reindex.
 */
function tailExtendsIndexedLeaf(entries: SessionEntry[], leafId: string): boolean {
  if (!leafId || tailHasUnsafeToolName(entries)) return false;
  for (const entry of entries) {
    if (FULL_REINDEX_ENTRY_TYPES.has(entry.type)) return false;
  }
  const leaf = sessionTranscriptLeafId(entries);
  if (!leaf) return true;
  const byId = new Map<string, SessionEntry>();
  for (const entry of entries) {
    if (entry.id) byId.set(entry.id, entry);
  }
  const seen = new Set<string>();
  let current: SessionEntry | undefined = byId.get(leaf);
  while (current) {
    if (!current.id || seen.has(current.id)) return false;
    seen.add(current.id);
    if (current.parentId === leafId) return true;
    if (!current.parentId) return false;
    current = byId.get(current.parentId);
  }
  return false;
}

function mergeTail(
  existing: SearchTranscriptContent,
  tailText: string,
  storedLeafId: string,
): { content: SearchTranscriptContent; leafId: string } | null {
  const entries = parseSessionEntries(tailText);
  if (!tailExtendsIndexedLeaf(entries, storedLeafId)) return null;
  const addition = extractSearchTranscriptFromEntries(entries);
  return {
    content: {
      userMessages: appendCapped(
        existing.userMessages,
        addition.userMessages,
        SEARCH_USER_MESSAGE_CAP,
      ),
      assistantMessages: appendCapped(
        existing.assistantMessages,
        addition.assistantMessages,
        SEARCH_ASSISTANT_MESSAGE_CAP,
      ),
      toolNames: mergeToolNames(existing.toolNames, addition.toolNames),
    },
    leafId: sessionTranscriptLeafId(entries) ?? storedLeafId,
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
  /**
   * One in-flight file index per session. A request that arrives while it runs
   * sets rerun so the follow-up reads the latest append instead of starting a
   * second read.
   */
  private fileIndexJobs = new Map<string, { rerun: boolean; done: Promise<void> }>();

  /** Set when the server has a durable Harness. Durable sessions are then indexed from it. */
  durableSource?: DurableSearchSource;
  /**
   * Test seam. Awaited after a file snapshot is read and before it is committed,
   * so a test can delete the session or sync while that read is in flight.
   */
  fileIndexGate?: () => Promise<void>;
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
    if (this.schemaVersion() === "6") {
      this.db.prepare("INSERT OR REPLACE INTO fts_schema VALUES ('version', ?)").run("7");
    }
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
      // v3–v6 upgrade in place; migrateToV6 finishes v5 data, then the
      // constructor stamps version 7 once the file cursor columns exist.
      const version = this.schemaVersion();
      if (version === "7") return;
      if (version === "6") {
        this.ensureFileCursorColumns();
        this.db.prepare("INSERT OR REPLACE INTO fts_schema VALUES ('version', ?)").run("7");
        return;
      }
      if (version === "5") {
        if (!this.ftsMetaColumnNames().has("durable_marker")) this.migrateDurableMarkerColumn();
        this.addFtsRowidColumn();
        this.ensureFileCursorColumns();
        return;
      }
      if (version === "4" || version === "3") {
        const columns = this.ftsMetaColumnNames();
        if (version === "3" || !columns.has("workspace_id") || !columns.has("title")) {
          this.migrateFtsMetaIdentityColumns();
        }
        this.migrateDurableMarkerColumn();
        this.addFtsRowidColumn();
        this.ensureFileCursorColumns();
        return;
      }

      // Unknown/older versions — drop and recreate at v7.
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
        fts_rowid INTEGER,
        jsonl_dev TEXT,
        jsonl_ino TEXT,
        jsonl_offset INTEGER,
        jsonl_boundary TEXT,
        jsonl_leaf_id TEXT
      );

      CREATE TABLE IF NOT EXISTS fts_schema (
        key TEXT PRIMARY KEY,
        value TEXT
      );

      INSERT OR REPLACE INTO fts_schema VALUES ('version', '7');
    `);
  }

  /** v6 → v7: byte cursor for append-only turn-end indexing. Existing rows stay NULL and full-reindex once. */
  private ensureFileCursorColumns(): void {
    const columns = this.ftsMetaColumnNames();
    if (!columns.has("jsonl_dev")) this.db.exec("ALTER TABLE fts_meta ADD COLUMN jsonl_dev TEXT");
    if (!columns.has("jsonl_ino")) this.db.exec("ALTER TABLE fts_meta ADD COLUMN jsonl_ino TEXT");
    if (!columns.has("jsonl_offset")) {
      this.db.exec("ALTER TABLE fts_meta ADD COLUMN jsonl_offset INTEGER");
    }
    if (!columns.has("jsonl_boundary")) {
      this.db.exec("ALTER TABLE fts_meta ADD COLUMN jsonl_boundary TEXT");
    }
    if (!columns.has("jsonl_leaf_id")) {
      this.db.exec("ALTER TABLE fts_meta ADD COLUMN jsonl_leaf_id TEXT");
    }
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
        durable_marker,
        jsonl_dev,
        jsonl_ino,
        jsonl_offset,
        jsonl_boundary,
        jsonl_leaf_id
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(session_id) DO UPDATE SET
        jsonl_path = excluded.jsonl_path,
        jsonl_mtime_ms = excluded.jsonl_mtime_ms,
        jsonl_size = excluded.jsonl_size,
        indexed_at = excluded.indexed_at,
        workspace_id = excluded.workspace_id,
        title = excluded.title,
        durable_marker = excluded.durable_marker,
        jsonl_dev = excluded.jsonl_dev,
        jsonl_ino = excluded.jsonl_ino,
        jsonl_offset = excluded.jsonl_offset,
        jsonl_boundary = excluded.jsonl_boundary,
        jsonl_leaf_id = excluded.jsonl_leaf_id
    `);

    this.stmtGetMeta = this.db.prepare(
      "SELECT jsonl_path, jsonl_mtime_ms, jsonl_size, workspace_id, title, durable_marker, jsonl_dev, jsonl_ino, jsonl_offset, jsonl_boundary, jsonl_leaf_id FROM fts_meta WHERE session_id = ?",
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
   * Index a single session. File-backed sessions resolve when the read finishes;
   * the read itself does not block the event loop on the whole file. Repeated
   * calls for one session share one in-flight read and one follow-up.
   * Server-durable sessions have no file and queue on the durable tail.
   */
  indexSession(sessionId: string): Promise<void> {
    const live = this.getSession(sessionId);
    if (live && this.isIndexedFromDurable(live)) {
      return this.syncDurableSession(sessionId).then(
        () => undefined,
        (err: unknown) => {
          log.error("search_index.durable_index.failed", {
            sessionId,
            error: err instanceof Error ? err.message : String(err),
          });
        },
      );
    }
    return this.enqueueFileIndex(sessionId);
  }

  private enqueueFileIndex(sessionId: string): Promise<void> {
    const existing = this.fileIndexJobs.get(sessionId);
    if (existing) {
      existing.rerun = true;
      return existing.done;
    }
    const job = { rerun: false, done: Promise.resolve() };
    this.fileIndexJobs.set(sessionId, job);
    job.done = this.pumpFileIndex(sessionId, job).finally(() => {
      if (this.fileIndexJobs.get(sessionId) === job) this.fileIndexJobs.delete(sessionId);
    });
    return job.done;
  }

  private async pumpFileIndex(sessionId: string, job: { rerun: boolean }): Promise<void> {
    // A thrown read must not drop a coalesced follow-up. Keep the shared promise
    // pending until that pass finishes, or the session is gone.
    do {
      job.rerun = false;
      try {
        await this.runFileIndex(sessionId);
      } catch (err: unknown) {
        log.error("search_index.file_index.failed", {
          sessionId,
          error: err instanceof Error ? err.message : String(err),
        });
      }
      if (this.closed || !this.getSession(sessionId)) return;
    } while (job.rerun);
  }

  private async pauseFileIndex(): Promise<void> {
    if (this.fileIndexGate) await this.fileIndexGate();
  }

  private markFileRerun(sessionId: string): void {
    const job = this.fileIndexJobs.get(sessionId);
    if (job) job.rerun = true;
  }

  /** Reload immediately before a write. A delete during the read must not be written back. */
  private liveFileSession(sessionId: string): Session | undefined {
    const live = this.getSession(sessionId);
    if (live && !live.ephemeral) return live;
    if (!this.closed) this.deleteSession(sessionId);
    return undefined;
  }

  private async runFileIndex(sessionId: string): Promise<void> {
    if (this.closed) return;
    const session = this.liveFileSession(sessionId);
    if (!session) return;
    if (this.isIndexedFromDurable(session)) {
      await this.syncDurableSession(sessionId);
      return;
    }

    const jsonlPath = session.piSessionFile;
    if (!jsonlPath) {
      await this.commitFileSnapshot(sessionId, null, emptyTranscript(), null);
      return;
    }

    let fileStat: FileStat | null;
    try {
      fileStat = fileStatFrom(await stat(jsonlPath, { bigint: true }));
    } catch {
      fileStat = null;
    }
    if (this.closed) return;
    if (!fileStat) {
      await this.commitFileSnapshot(sessionId, null, emptyTranscript(), null);
      return;
    }

    const meta = this.getMeta(sessionId);
    const cursor = meta ? cursorFromMeta(meta) : null;
    const indexed = this.indexedTranscript(sessionId);
    if (
      cursor &&
      indexed &&
      meta?.jsonl_path === jsonlPath &&
      cursor.dev === fileStat.dev &&
      cursor.ino === fileStat.ino &&
      fileStat.size >= cursor.offset
    ) {
      const boundary = await readBoundary(jsonlPath, cursor.offset);
      if (this.closed) return;
      if (boundary === cursor.boundary) {
        const lineBoundary =
          cursor.offset === 0 ||
          (await readByteRange(jsonlPath, cursor.offset - 1, cursor.offset))[0] === 0x0a;
        if (!lineBoundary) {
          // Fall through to a full reindex. The stored offset splits a line.
        } else if (fileStat.size === cursor.offset) {
          const title = extractSessionTitle(session);
          const workspaceId = session.workspaceId ?? "";
          const unchanged =
            meta.title === title &&
            meta.workspace_id === workspaceId &&
            meta.jsonl_mtime_ms === Math.floor(fileStat.mtimeMs);
          // Still confirm the snapshot when nothing else changed, so a delete
          // during the stat cannot be ignored.
          if (!unchanged) {
            await this.commitFileSnapshot(
              sessionId,
              {
                path: jsonlPath,
                stat: fileStat,
                boundaryAtOffset: boundary,
                offset: cursor.offset,
              },
              indexed,
              cursor,
            );
          } else {
            await this.commitFileSnapshot(
              sessionId,
              {
                path: jsonlPath,
                stat: fileStat,
                boundaryAtOffset: boundary,
                offset: cursor.offset,
              },
              indexed,
              cursor,
              { skipUnchangedWrite: true },
            );
          }
          return;
        } else {
          const tail = await readByteRange(jsonlPath, cursor.offset, fileStat.size);
          if (this.closed) return;
          const merged = mergeTail(indexed, tail.toString("utf8"), cursor.leafId);
          if (merged) {
            const boundaryNow = await readBoundary(jsonlPath, fileStat.size);
            if (this.closed) return;
            await this.commitFileSnapshot(
              sessionId,
              {
                path: jsonlPath,
                stat: fileStat,
                boundaryAtOffset: boundary,
                offset: cursor.offset,
              },
              merged.content,
              cursorForFile(fileStat, boundaryNow, merged.leafId),
            );
            return;
          }
        }
      }
    }

    const full = await this.readFullTranscript(jsonlPath, fileStat.size);
    if (this.closed || !full) return;
    const boundaryNow = await readBoundary(jsonlPath, fileStat.size);
    if (this.closed) return;
    await this.commitFileSnapshot(
      sessionId,
      { path: jsonlPath, stat: fileStat, boundaryAtOffset: boundaryNow, offset: fileStat.size },
      full.transcript,
      cursorForFile(fileStat, boundaryNow, full.leafId),
    );
  }

  /**
   * Shutdown path. Prefer the stored cursor so a large session is not re-read
   * in full while the process is exiting.
   */
  private indexFileSessionSync(sessionId: string): void {
    const session = this.getSession(sessionId);
    if (!session || session.ephemeral) {
      this.deleteSession(sessionId);
      return;
    }
    if (this.isIndexedFromDurable(session)) return;
    const jsonlPath = session.piSessionFile;
    if (!jsonlPath) {
      this.writeFileTranscript(session, emptyTranscript(), null);
      return;
    }
    let fileStat: FileStat | null;
    try {
      fileStat = fileStatFrom(statSync(jsonlPath, { bigint: true }));
    } catch {
      fileStat = null;
    }
    if (!fileStat) {
      this.writeFileTranscript(session, emptyTranscript(), null);
      return;
    }

    const meta = this.getMeta(sessionId);
    const cursor = meta ? cursorFromMeta(meta) : null;
    const indexed = this.indexedTranscript(sessionId);
    if (
      cursor &&
      indexed &&
      meta?.jsonl_path === jsonlPath &&
      cursor.dev === fileStat.dev &&
      cursor.ino === fileStat.ino &&
      fileStat.size >= cursor.offset &&
      readBoundarySync(jsonlPath, cursor.offset) === cursor.boundary &&
      offsetIsLineBoundarySync(jsonlPath, cursor.offset)
    ) {
      if (fileStat.size === cursor.offset) {
        this.writeFileTranscript(session, indexed, { path: jsonlPath, stat: fileStat, cursor });
        return;
      }
      const tail = readByteRangeSync(jsonlPath, cursor.offset, fileStat.size);
      const merged = mergeTail(indexed, tail.toString("utf8"), cursor.leafId);
      if (merged) {
        this.writeFileTranscript(session, merged.content, {
          path: jsonlPath,
          stat: fileStat,
          cursor: cursorForFile(
            fileStat,
            readBoundarySync(jsonlPath, fileStat.size),
            merged.leafId,
          ),
        });
        return;
      }
    }

    // Cursor miss at shutdown: leave the row. A whole-file read here would
    // block process exit. The next boot reindexes.
  }

  private async readFullTranscript(
    jsonlPath: string,
    size: number,
  ): Promise<{ transcript: SearchTranscriptContent; leafId: string | null } | null> {
    // Small files stay one read. Large files yield between chunks so a cold
    // reindex cannot stall the event loop for the whole file.
    if (size < 256 * 1024) {
      const bytes = await readByteRange(jsonlPath, 0, size);
      return this.finishFullTranscript(parseSessionEntries(bytes.toString("utf8")));
    }

    const handle = await open(jsonlPath, "r");
    const entries: SessionEntry[] = [];
    const decoder = new TextDecoder("utf-8");
    let leftover = "";
    const chunkSize = 1024 * 1024;
    const buffer = Buffer.alloc(chunkSize);
    try {
      let position = 0;
      while (position < size) {
        if (this.closed) return null;
        const length = Math.min(chunkSize, size - position);
        const { bytesRead } = await handle.read(buffer, 0, length, position);
        if (bytesRead === 0) break;
        position += bytesRead;
        leftover += decoder.decode(buffer.subarray(0, bytesRead), { stream: true });
        const newline = leftover.lastIndexOf("\n");
        if (newline >= 0) {
          entries.push(...parseSessionEntries(leftover.slice(0, newline)));
          leftover = leftover.slice(newline + 1);
        }
        if (entries.length > 0 && entries.length % FULL_REINDEX_YIELD_EVERY === 0) {
          await new Promise<void>((resolve) => setImmediate(resolve));
          if (this.closed) return null;
        }
      }
      leftover += decoder.decode();
      if (leftover.trim()) entries.push(...parseSessionEntries(leftover));
    } finally {
      await handle.close();
    }
    if (this.closed) return null;
    return this.finishFullTranscript(entries);
  }

  private async finishFullTranscript(
    entries: SessionEntry[],
  ): Promise<{ transcript: SearchTranscriptContent; leafId: string | null } | null> {
    const transcript = await extractSearchTranscriptFromEntriesYielding(
      entries,
      FULL_REINDEX_YIELD_EVERY,
      () => this.closed,
    );
    if (!transcript) return null;
    return { transcript, leafId: sessionTranscriptLeafId(entries) };
  }

  private getMeta(sessionId: string): FtsMetaRow | undefined {
    return this.stmtGetMeta.get(sessionId) as FtsMetaRow | undefined;
  }

  private cursorForIndexedFile(path: string, leafId: string | null): FileCursor | null {
    try {
      const fileStat = fileStatFrom(statSync(path, { bigint: true }));
      if (!fileStat) return null;
      return cursorForFile(fileStat, readBoundarySync(path, fileStat.size), leafId);
    } catch {
      return null;
    }
  }

  /**
   * Startup sync uses this when the file grew but the stored prefix is still
   * the indexed prefix. Returns null when the caller must read the whole file.
   */
  private readIncrementalTranscriptSync(
    sessionId: string,
    jsonlPath: string,
  ): {
    content: SearchTranscriptContent;
    stat: FileStat;
    cursor: FileCursor;
    bytesRead: number;
  } | null {
    const meta = this.getMeta(sessionId);
    const stored = meta ? cursorFromMeta(meta) : null;
    const indexed = this.indexedTranscript(sessionId);
    if (!stored || !indexed || meta?.jsonl_path !== jsonlPath) return null;
    let fileStat: FileStat | null;
    try {
      fileStat = fileStatFrom(statSync(jsonlPath, { bigint: true }));
    } catch {
      return null;
    }
    if (!fileStat || fileStat.size <= stored.offset) return null;
    if (fileStat.dev !== stored.dev || fileStat.ino !== stored.ino) return null;
    if (readBoundarySync(jsonlPath, stored.offset) !== stored.boundary) return null;
    if (!offsetIsLineBoundarySync(jsonlPath, stored.offset)) return null;
    const tail = readByteRangeSync(jsonlPath, stored.offset, fileStat.size);
    const merged = mergeTail(indexed, tail.toString("utf8"), stored.leafId);
    if (!merged) return null;
    return {
      content: merged.content,
      stat: fileStat,
      cursor: cursorForFile(fileStat, readBoundarySync(jsonlPath, fileStat.size), merged.leafId),
      bytesRead: tail.length,
    };
  }

  private indexedTranscript(sessionId: string): SearchTranscriptContent | null {
    const row = this.stmtGetIndexedRow.get(sessionId) as
      { user_messages: string; assistant_messages: string; tool_names: string } | undefined;
    if (!row) return null;
    return {
      userMessages: row.user_messages,
      assistantMessages: row.assistant_messages,
      toolNames: row.tool_names,
    };
  }

  /**
   * Re-stat and re-read the boundary at the snapshot offset. A rewrite during
   * the read must not be committed.
   */
  private async fileSnapshotHolds(
    path: string,
    snapshot: FileStat,
    offset: number,
    boundary: string,
  ): Promise<boolean> {
    let after: FileStat | null;
    try {
      after = fileStatFrom(await stat(path, { bigint: true }));
    } catch {
      return false;
    }
    if (
      !after ||
      after.dev !== snapshot.dev ||
      after.ino !== snapshot.ino ||
      after.size !== snapshot.size
    ) {
      return false;
    }
    return (await readBoundary(path, offset)) === boundary;
  }

  /**
   * Pause for tests, refuse a snapshot the file no longer matches, then reload
   * the session with no further await before the write.
   */
  private async commitFileSnapshot(
    sessionId: string,
    snapshot: {
      path: string;
      stat: FileStat;
      boundaryAtOffset: string;
      offset: number;
    } | null,
    content: SearchTranscriptContent,
    cursor: FileCursor | null,
    options: { skipUnchangedWrite?: boolean } = {},
  ): Promise<void> {
    await this.pauseFileIndex();
    if (this.closed) return;
    if (snapshot) {
      const holds = await this.fileSnapshotHolds(
        snapshot.path,
        snapshot.stat,
        snapshot.offset,
        snapshot.boundaryAtOffset,
      );
      if (!holds) {
        this.markFileRerun(sessionId);
        return;
      }
    }
    const live = this.liveFileSession(sessionId);
    if (!live || options.skipUnchangedWrite) return;
    this.writeFileTranscript(
      live,
      content,
      snapshot && cursor ? { path: snapshot.path, stat: snapshot.stat, cursor } : null,
    );
  }

  private writeFileTranscript(
    session: Session,
    content: SearchTranscriptContent,
    file: { path: string; stat: FileStat; cursor: FileCursor } | null,
  ): boolean {
    if (this.closed) return false;
    let wrote = false;
    const title = extractSessionTitle(session);
    const workspaceId = session.workspaceId ?? "";
    this.db.transaction(() => {
      if (file) {
        const stored = this.getMeta(session.id);
        const storedCursor =
          stored && stored.jsonl_path === file.path ? cursorFromMeta(stored) : null;
        if (storedCursor && storedCursorIsNewer(storedCursor, file.cursor, file.stat.size)) {
          this.markFileRerun(session.id);
          return;
        }
      }
      wrote = true;
      this.upsertRow(
        session.id,
        workspaceId,
        title,
        content.userMessages,
        content.assistantMessages,
        content.toolNames,
      );
      this.upsertMeta(
        session.id,
        file?.path ?? null,
        file ? Math.floor(file.stat.mtimeMs) : 0,
        file?.stat.size ?? 0,
        workspaceId,
        title,
        null,
        file?.cursor ?? null,
      );
    })();
    return wrote;
  }

  private upsertMeta(
    sessionId: string,
    jsonlPath: string | null,
    jsonlMtimeMs: number,
    jsonlSize: number,
    workspaceId: string,
    title: string,
    durableMarker: string | null = null,
    cursor: FileCursor | null = null,
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
      cursor?.dev ?? null,
      cursor?.ino ?? null,
      cursor?.offset ?? null,
      cursor?.boundary ?? null,
      cursor?.leafId ?? null,
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
    void this.indexSession(sessionId).catch((err: unknown) => {
      log.error("search_index.file_index.failed", {
        sessionId,
        error: err instanceof Error ? err.message : String(err),
      });
    });
  }

  private flushPending(): void {
    this.reindexTimer = null;
    const batch = [...this.pendingReindex];
    this.pendingReindex.clear();

    for (const id of batch) {
      void this.indexSession(id).catch((err: unknown) => {
        log.error("search_index.file_index.failed", {
          sessionId: id,
          error: err instanceof Error ? err.message : String(err),
        });
      });
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
    if (meta.workspace_id !== workspaceId || meta.title !== title) return false;
    if (fingerprint.jsonlPath) this.ensureFileCursor(liveSession.id, fingerprint.jsonlPath);
    return true;
  }

  /**
   * An unchanged file indexed before the cursor columns existed has no offset.
   * Record identity and the tail leaf without rewriting FTS, so the next turn
   * reads only the append.
   */
  private ensureFileCursor(sessionId: string, jsonlPath: string): void {
    const meta = this.getMeta(sessionId);
    if (!meta || cursorFromMeta(meta)) return;
    let fileStat: FileStat | null;
    try {
      fileStat = fileStatFrom(statSync(jsonlPath, { bigint: true }));
    } catch {
      return;
    }
    if (!fileStat) return;
    this.upsertMeta(
      sessionId,
      jsonlPath,
      Math.floor(fileStat.mtimeMs),
      fileStat.size,
      meta.workspace_id ?? "",
      meta.title ?? "",
      meta.durable_marker,
      cursorForFile(
        fileStat,
        readBoundarySync(jsonlPath, fileStat.size),
        leafIdFromFileTail(jsonlPath, fileStat.size),
      ),
    );
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

  /** True when startup must read the whole file. The background pass uses the yielding reader. */
  private needsYieldingFullRead(session: Session): boolean {
    const live = this.getSession(session.id);
    if (!live || live.ephemeral || this.isIndexedFromDurable(live)) return false;
    if (this.fileIndexJobs.has(live.id)) return false;
    const jsonlPath = live.piSessionFile;
    if (!jsonlPath) return false;
    const fingerprint = this.readTranscriptFingerprint(live);
    if (!fingerprint.fileStat) return false;
    const meta = this.getMeta(live.id);
    if (
      meta &&
      meta.jsonl_mtime_ms === fingerprint.jsonlMtimeMs &&
      meta.jsonl_size === fingerprint.jsonlSize &&
      meta.jsonl_path === fingerprint.expectedJsonlPath
    ) {
      return false;
    }
    return !this.incrementalCursorHolds(live.id, jsonlPath);
  }

  private incrementalCursorHolds(sessionId: string, jsonlPath: string): boolean {
    const meta = this.getMeta(sessionId);
    const stored = meta ? cursorFromMeta(meta) : null;
    if (!stored || !this.indexedTranscript(sessionId) || meta?.jsonl_path !== jsonlPath)
      return false;
    let fileStat: FileStat | null;
    try {
      fileStat = fileStatFrom(statSync(jsonlPath, { bigint: true }));
    } catch {
      return false;
    }
    if (!fileStat || fileStat.size <= stored.offset) return false;
    if (fileStat.dev !== stored.dev || fileStat.ino !== stored.ino) return false;
    if (readBoundarySync(jsonlPath, stored.offset) !== stored.boundary) return false;
    return offsetIsLineBoundarySync(jsonlPath, stored.offset);
  }

  /** Startup full read. Yields through the file instead of readFileSync. */
  private async syncSessionYielding(session: Session): Promise<SearchIndexSyncResult> {
    const result = emptySyncResult();
    if (this.fileIndexJobs.has(session.id)) {
      result.skipped = 1;
      return result;
    }
    const live = this.getSession(session.id);
    if (!live || live.ephemeral) return this.removeIndexedSession(session.id);
    if (this.isIndexedFromDurable(live)) {
      this.lateDurableSessionIds.add(live.id);
      return result;
    }
    const jsonlPath = live.piSessionFile;
    if (!jsonlPath) return this.syncSession(live, new Set());
    let fileStat: FileStat | null;
    try {
      fileStat = fileStatFrom(await stat(jsonlPath, { bigint: true }));
    } catch {
      fileStat = null;
    }
    if (!fileStat) return this.syncSession(live, new Set());
    const hadRow = this.getMeta(live.id) !== undefined;
    if (this.fileIndexJobs.has(live.id)) {
      result.skipped = 1;
      return result;
    }
    const full = await this.readFullTranscript(jsonlPath, fileStat.size);
    if (this.closed || !full) return result;
    if (this.fileIndexJobs.has(live.id)) {
      result.skipped = 1;
      return result;
    }
    const boundary = await readBoundary(jsonlPath, fileStat.size);
    await this.commitFileSnapshot(
      live.id,
      { path: jsonlPath, stat: fileStat, boundaryAtOffset: boundary, offset: fileStat.size },
      full.transcript,
      cursorForFile(fileStat, boundary, full.leafId),
    );
    if (!this.getSession(live.id)) {
      if (hadRow) result.removed = 1;
      return result;
    }
    const stored = this.getMeta(live.id);
    const storedCursor = stored ? cursorFromMeta(stored) : null;
    if (
      !storedCursor ||
      storedCursor.offset !== fileStat.size ||
      storedCursor.boundary !== boundary
    ) {
      result.skipped = 1;
      return result;
    }
    result.transcriptsRead = 1;
    result.transcriptsReindexed = 1;
    result.transcriptBytesRead = fileStat.size;
    if (hadRow) result.reindexed = 1;
    else result.added = 1;
    return result;
  }

  private syncSession(session: Session, ftsIds: ReadonlySet<string>): SearchIndexSyncResult {
    const result = emptySyncResult();
    // An in-flight turn-end read owns this session. Writing here can land an
    // older snapshot over a newer cursor.
    if (this.fileIndexJobs.has(session.id)) {
      result.skipped = 1;
      return result;
    }
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
      if (jsonlPath) this.ensureFileCursor(sessionId, jsonlPath);
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
          null,
          meta ? cursorFromMeta(meta as FtsMetaRow) : null,
        );
        result.reindexed = 1;
        result.reusedIndexedTranscript = 1;
        return result;
      }
    }

    const incremental = jsonlPath ? this.readIncrementalTranscriptSync(sessionId, jsonlPath) : null;
    if (incremental) {
      this.upsertRow(
        sessionId,
        workspaceId,
        title,
        incremental.content.userMessages,
        incremental.content.assistantMessages,
        incremental.content.toolNames,
      );
      this.upsertMeta(
        sessionId,
        jsonlPath ?? null,
        Math.floor(incremental.stat.mtimeMs),
        incremental.stat.size,
        workspaceId,
        title,
        null,
        incremental.cursor,
      );
      result.reindexed = 1;
      result.transcriptsRead = 1;
      result.transcriptsReindexed = 1;
      result.transcriptBytesRead = incremental.bytesRead;
      return result;
    }

    // Blocking sync() is the test oracle for small files. Production startup
    // peels this case off and uses syncSessionYielding so it does not readFileSync.
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
      null,
      fileStat && jsonlPath ? this.cursorForIndexedFile(jsonlPath, content.leafId) : null,
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
      if (
        this.fileIndexJobs.has(sessions[nextIndex].id) ||
        this.needsYieldingFullRead(sessions[nextIndex])
      ) {
        break;
      }
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
          if (this.needsYieldingFullRead(sessions[nextIndex])) break;
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

      const next = fileSessions[sessionIndex];
      if (next && this.needsYieldingFullRead(next)) {
        mergeSyncResults(result, await this.syncSessionYielding(next));
        sessionsChecked++;
        sessionIndex++;
        if (sessionIndex < fileSessions.length) await yieldBetweenBatches();
        continue;
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
    if (this.reindexTimer) {
      clearTimeout(this.reindexTimer);
      this.reindexTimer = null;
    }
    const pending = new Set([...this.pendingReindex, ...this.fileIndexJobs.keys()]);
    this.pendingReindex.clear();
    for (const sessionId of pending) {
      try {
        this.indexFileSessionSync(sessionId);
      } catch (err: unknown) {
        log.error("search_index.file_index.failed", {
          sessionId,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }
    this.closed = true;
    this.db.close();
  }
}
