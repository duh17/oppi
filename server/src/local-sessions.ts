/**
 * Local pi session discovery.
 *
 * Scans ~/.pi/agent/sessions/ to find sessions started from TUI pi
 * that aren't managed by the oppi server. These can be imported into
 * a workspace for mobile resume.
 *
 * Security: only reads from the fixed pi sessions directory. Resolves
 * symlinks before path validation. All paths returned are real paths.
 */

import {
  chmodSync,
  existsSync,
  mkdirSync,
  openSync,
  readSync,
  closeSync,
  realpathSync,
} from "node:fs";
import { stat, readdir } from "node:fs/promises";
import { join, resolve } from "node:path";
import { homedir } from "node:os";
import {
  DEFAULT_SESSION_JSONL_META_READ_BYTES,
  readSessionJsonlMeta,
} from "./session-jsonl-meta.js";
import { openDatabase, type SqliteDatabase } from "./sqlite-compat.js";
import type { LocalSession, Session } from "./types.js";

/** Default root of pi agent sessions when OPPI_LOCAL_SESSIONS_ROOT is unset. */
const DEFAULT_PI_SESSIONS_ROOT = join(homedir(), ".pi", "agent", "sessions");

/**
 * Resolve the configured pi sessions root.
 *
 * Read on each call so tests can point OPPI_LOCAL_SESSIONS_ROOT at a temp tree
 * without relying on module-load timing. Production servers typically set the
 * env once at process start (or leave the home default).
 */
function resolvePiSessionsRoot(): string {
  const override = process.env.OPPI_LOCAL_SESSIONS_ROOT?.trim();
  return override && override.length > 0 ? override : DEFAULT_PI_SESSIONS_ROOT;
}

/**
 * Return the canonical pi sessions root, resolving symlinks.
 * Used for path confinement validation.
 */
export function getPiSessionsRoot(): string {
  const root = resolvePiSessionsRoot();
  try {
    return realpathSync(root);
  } catch {
    return root;
  }
}

/**
 * Validate that a file path is confined within the pi sessions directory
 * and points to a valid .jsonl session file.
 *
 * Resolves symlinks before checking. Returns the canonical path if valid,
 * or null with an error message if not.
 */
export function validateLocalSessionPath(filePath: string): { path: string } | { error: string } {
  const resolved = resolve(filePath);

  // Must end in .jsonl
  if (!resolved.endsWith(".jsonl")) {
    return { error: "Path must be a .jsonl file" };
  }

  // Must exist
  if (!existsSync(resolved)) {
    return { error: "File not found" };
  }

  // Resolve symlinks for both the file and the root
  let realPath: string;
  try {
    realPath = realpathSync(resolved);
  } catch {
    return { error: "Cannot resolve path" };
  }

  const realRoot = getPiSessionsRoot();

  // Must be under pi sessions root
  if (!realPath.startsWith(realRoot + "/") && realPath !== realRoot) {
    return { error: "Path must be under ~/.pi/agent/sessions/" };
  }

  // Validate JSONL header
  const header = readSessionHeader(realPath);
  if (!header) {
    return { error: "Not a valid pi session file" };
  }

  return { path: realPath };
}

/**
 * Validate that a session's CWD is compatible with a workspace's hostMount.
 * The session CWD must equal or be a subdirectory of the workspace mount.
 */
export function validateCwdAlignment(sessionCwd: string, workspaceHostMount: string): boolean {
  const resolvedCwd = resolve(sessionCwd.replace(/^~/, homedir()));
  const resolvedMount = resolve(workspaceHostMount.replace(/^~/, homedir()));

  return resolvedCwd === resolvedMount || resolvedCwd.startsWith(resolvedMount + "/");
}

/**
 * Control-session Pi artifacts must never appear as importable local TUI rows.
 * Matches the real data-dir control cwd and the legacy display-label path
 * (`.../Oppi Control`) created before control sessions stopped persisting that
 * label as SessionManager cwd.
 */
export function isControlSessionLocalArtifact(
  sessionCwd: string,
  options: { dataDir?: string } = {},
): boolean {
  const trimmed = sessionCwd.trim();
  if (!trimmed) return false;
  if (trimmed === "Oppi Control") return true;

  const resolvedCwd = resolve(trimmed.replace(/^~/, homedir()));
  if (resolvedCwd.split(/[\\/]/).at(-1) === "Oppi Control") {
    return true;
  }

  const dataDir = options.dataDir?.trim();
  if (!dataDir) return false;

  const controlRoot = resolve(dataDir.replace(/^~/, homedir()), "control-sessions");
  return resolvedCwd === controlRoot || resolvedCwd.startsWith(`${controlRoot}/`);
}

/** Minimal session header from first line of JSONL. */
interface SessionHeaderData {
  id: string;
  cwd: string;
  timestamp: string;
  version?: number;
}

/**
 * Read just the session header (first line) from a JSONL file.
 * Uses a small buffer read — does not load the entire file.
 */
function readSessionHeader(filePath: string): SessionHeaderData | null {
  try {
    const fd = openSync(filePath, "r");
    // Read enough for a typical header (cwd can be long)
    const buffer = Buffer.alloc(2048);
    const bytesRead = readSync(fd, buffer, 0, 2048, 0);
    closeSync(fd);

    const firstLine = buffer.toString("utf8", 0, bytesRead).split("\n")[0];
    if (!firstLine) return null;

    const parsed = JSON.parse(firstLine);
    if (parsed.type !== "session" || typeof parsed.id !== "string") {
      return null;
    }

    return {
      id: parsed.id,
      cwd: typeof parsed.cwd === "string" ? parsed.cwd : "",
      timestamp: typeof parsed.timestamp === "string" ? parsed.timestamp : "",
      version: typeof parsed.version === "number" ? parsed.version : undefined,
    };
  } catch {
    return null;
  }
}

/**
 * Extract session name, first user message, model, and approximate
 * message count from a JSONL file.
 *
 * Shared reader owns JSONL parsing. This catalog path keeps the 16KB
 * budget, the 200-char firstMessage preview, and the size heuristic
 * because those are discovery extras, not file-format rules.
 */
async function extractSessionMetadata(
  filePath: string,
  fileSize: number,
): Promise<{ name?: string; firstMessage?: string; model?: string; messageCount: number }> {
  const maxBytes = Math.min(fileSize, DEFAULT_SESSION_JSONL_META_READ_BYTES);
  const meta = readSessionJsonlMeta(filePath, {
    maxBytes,
    firstMessageMaxChars: 200,
    stopWhen: ["firstMessage", "model"],
  });

  let messageCount = meta.messageCount;

  // Estimate message count from file size if we only read a chunk.
  // Average JSONL line for a message event is ~1-2KB.
  // Skip the heuristic when the head read failed so an unreadable file
  // stays at messageCount 0 instead of inventing a count from empty lines.
  if (fileSize > maxBytes && meta.scannedBytes > 0) {
    const avgLineSize = maxBytes / Math.max(meta.scannedLineCount, 1);
    const estimatedTotalLines = Math.round(fileSize / avgLineSize);
    // Roughly 40% of lines are message events in a typical session
    messageCount = Math.max(messageCount, Math.round(estimatedTotalLines * 0.4));
  }

  return {
    name: meta.name,
    firstMessage: meta.firstMessage,
    model: meta.model,
    messageCount,
  };
}

// ── Per-file mtime cache ──
// Stat is cheap (~0.01ms per file). Reading 16KB + parsing JSON is not.
// Cache metadata keyed by realpath → { mtimeMs, session }. On each
// discovery call we stat all files but only re-read those whose mtime
// changed. First call reads everything; subsequent calls are near-instant.

const metadataCache = new Map<string, { mtimeMs: number; session: LocalSession }>();

interface TuiSessionCatalogRow {
  path: string;
  pi_session_id: string;
  cwd: string;
  name: string | null;
  first_message: string | null;
  model: string | null;
  message_count: number;
  created_at: number;
  last_modified: number;
  size_bytes: number;
  mtime_ms: number;
}

export interface LocalSessionCatalogSnapshot {
  sessions: LocalSession[];
  lastScannedAt?: number;
}

export interface KnownLocalSessionIdentities {
  files?: Set<string>;
  piSessionIds?: Set<string>;
}

type KnownLocalSessions = Set<string> | KnownLocalSessionIdentities | undefined;

function canonicalLocalSessionFilePath(path: string): string {
  const resolved = resolve(path);
  if (!existsSync(resolved)) return resolved;
  try {
    return realpathSync(resolved);
  } catch {
    return resolved;
  }
}

export function collectKnownLocalSessionIdentities(
  sessions: Iterable<Pick<Session, "id" | "piSessionFile" | "piSessionFiles">>,
): KnownLocalSessionIdentities {
  const files = new Set<string>();
  const piSessionIds = new Set<string>();

  for (const session of sessions) {
    if (session.id) {
      piSessionIds.add(session.id);
    }
    if (session.piSessionFile) {
      files.add(canonicalLocalSessionFilePath(session.piSessionFile));
    }
    for (const file of session.piSessionFiles ?? []) {
      files.add(canonicalLocalSessionFilePath(file));
    }
  }

  return { files, piSessionIds };
}

function isKnownLocalSession(
  row: Pick<TuiSessionCatalogRow, "path" | "pi_session_id">,
  known: KnownLocalSessions,
): boolean {
  if (!known) return false;
  if (known instanceof Set) return known.has(row.path);
  return known.files?.has(row.path) === true || known.piSessionIds?.has(row.pi_session_id) === true;
}

function isKnownLocalSessionValue(session: LocalSession, known: KnownLocalSessions): boolean {
  if (!known) return false;
  if (known instanceof Set) return known.has(session.path);
  return (
    known.files?.has(session.path) === true || known.piSessionIds?.has(session.piSessionId) === true
  );
}

class TuiSessionCatalog {
  private readonly db: SqliteDatabase;

  constructor(dataDir: string) {
    mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    const dbPath = join(dataDir, "session-state.db");
    this.db = openDatabase(dbPath);
    chmodSync(dbPath, 0o600);
    this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec("PRAGMA synchronous = NORMAL");
    this.ensureSchema();
  }

  close(): void {
    this.db.close();
  }

  rowsByPath(): Map<string, TuiSessionCatalogRow> {
    const rows = this.db.prepare("SELECT * FROM tui_session_files").all() as TuiSessionCatalogRow[];
    return new Map(rows.map((row) => [row.path, row]));
  }

  listRows(): TuiSessionCatalogRow[] {
    return this.db
      .prepare("SELECT * FROM tui_session_files ORDER BY last_modified DESC, path ASC")
      .all() as TuiSessionCatalogRow[];
  }

  upsert(session: LocalSession, sizeBytes: number, mtimeMs: number): void {
    this.db
      .prepare(
        `INSERT INTO tui_session_files (
          path,
          pi_session_id,
          cwd,
          name,
          first_message,
          model,
          message_count,
          created_at,
          last_modified,
          size_bytes,
          mtime_ms,
          updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
          pi_session_id = excluded.pi_session_id,
          cwd = excluded.cwd,
          name = excluded.name,
          first_message = excluded.first_message,
          model = excluded.model,
          message_count = excluded.message_count,
          created_at = excluded.created_at,
          last_modified = excluded.last_modified,
          size_bytes = excluded.size_bytes,
          mtime_ms = excluded.mtime_ms,
          updated_at = excluded.updated_at`,
      )
      .run(
        session.path,
        session.piSessionId,
        session.cwd,
        session.name ?? null,
        session.firstMessage ?? null,
        session.model ?? null,
        session.messageCount,
        session.createdAt,
        session.lastModified,
        sizeBytes,
        mtimeMs,
        Date.now(),
      );
  }

  deletePath(path: string): void {
    this.db.prepare("DELETE FROM tui_session_files WHERE path = ?").run(path);
  }

  deleteMissing(livePaths: Set<string>): void {
    const deleteStmt = this.db.prepare("DELETE FROM tui_session_files WHERE path = ?");
    this.db.transaction(() => {
      for (const row of this.listRows()) {
        if (!livePaths.has(row.path)) {
          deleteStmt.run(row.path);
        }
      }
    })();
  }

  getLastScannedAt(): number | undefined {
    const row = this.db
      .prepare("SELECT value FROM tui_session_catalog_state WHERE key = 'last_scanned_at'")
      .get() as { value?: string } | undefined;
    if (!row?.value) {
      return undefined;
    }

    const value = Number.parseInt(row.value, 10);
    return Number.isFinite(value) ? value : undefined;
  }

  setLastScannedAt(timestampMs: number): void {
    this.db
      .prepare(
        `INSERT INTO tui_session_catalog_state (key, value)
         VALUES ('last_scanned_at', ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
      )
      .run(String(timestampMs));
  }

  clearLastScannedAt(): void {
    this.db.prepare("DELETE FROM tui_session_catalog_state WHERE key = 'last_scanned_at'").run();
  }

  private ensureSchema(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS tui_session_files (
        path TEXT PRIMARY KEY,
        pi_session_id TEXT NOT NULL,
        cwd TEXT NOT NULL,
        name TEXT,
        first_message TEXT,
        model TEXT,
        message_count INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        last_modified INTEGER NOT NULL,
        size_bytes INTEGER NOT NULL,
        mtime_ms REAL NOT NULL,
        updated_at INTEGER NOT NULL
      );

      CREATE INDEX IF NOT EXISTS tui_session_files_mtime_idx
        ON tui_session_files (last_modified DESC, path ASC);

      CREATE INDEX IF NOT EXISTS tui_session_files_cwd_idx
        ON tui_session_files (cwd);

      CREATE TABLE IF NOT EXISTS tui_session_catalog_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    `);
  }
}

function rowToLocalSession(row: TuiSessionCatalogRow): LocalSession {
  return {
    path: row.path,
    piSessionId: row.pi_session_id,
    cwd: row.cwd,
    ...(row.name ? { name: row.name } : {}),
    ...(row.first_message ? { firstMessage: row.first_message } : {}),
    ...(row.model ? { model: row.model } : {}),
    messageCount: row.message_count,
    createdAt: row.created_at,
    lastModified: row.last_modified,
  };
}

function buildLocalSession(
  realFile: string,
  mtimeMs: number,
  header: SessionHeaderData,
  metadata: { name?: string; firstMessage?: string; model?: string; messageCount: number },
): LocalSession {
  return {
    path: realFile,
    piSessionId: header.id,
    cwd: header.cwd,
    name: metadata.name,
    firstMessage: metadata.firstMessage,
    model: metadata.model,
    messageCount: metadata.messageCount,
    createdAt: new Date(header.timestamp).getTime() || mtimeMs,
    lastModified: mtimeMs,
  };
}

async function refreshTuiSessionCatalog(
  catalog: TuiSessionCatalog,
  needsRead: { path: string; size: number; mtimeMs: number }[],
): Promise<void> {
  const BATCH_SIZE = 20;
  for (let i = 0; i < needsRead.length; i += BATCH_SIZE) {
    const batch = needsRead.slice(i, i + BATCH_SIZE);
    await Promise.all(
      batch.map(async ({ path: realFile, size, mtimeMs }) => {
        const header = readSessionHeader(realFile);
        if (!header) {
          catalog.deletePath(realFile);
          return;
        }

        const metadata = await extractSessionMetadata(realFile, size);
        const session = buildLocalSession(realFile, mtimeMs, header, metadata);
        catalog.upsert(session, size, mtimeMs);
      }),
    );
  }
}

async function refreshInMemoryLocalSessionCache(
  needsRead: { path: string; size: number; mtimeMs: number }[],
): Promise<void> {
  const BATCH_SIZE = 20;
  for (let i = 0; i < needsRead.length; i += BATCH_SIZE) {
    const batch = needsRead.slice(i, i + BATCH_SIZE);
    await Promise.all(
      batch.map(async ({ path: realFile, size, mtimeMs }) => {
        const header = readSessionHeader(realFile);
        if (!header) {
          metadataCache.delete(realFile);
          return;
        }

        const metadata = await extractSessionMetadata(realFile, size);
        const session = buildLocalSession(realFile, mtimeMs, header, metadata);
        metadataCache.set(realFile, { mtimeMs, session });
      }),
    );
  }
}

/** Invalidate cached local-session projections after import/delete. */
export function invalidateLocalSessionsCache(options: { dataDir?: string } = {}): void {
  metadataCache.clear();

  if (!options.dataDir) {
    return;
  }

  try {
    const catalog = new TuiSessionCatalog(options.dataDir);
    try {
      catalog.clearLastScannedAt();
    } finally {
      catalog.close();
    }
  } catch {
    // Best-effort invalidation only; callers will repopulate on next discovery.
  }
}

export function deleteCatalogedLocalSessionPaths(
  paths: Iterable<string>,
  options: { dataDir: string },
): void {
  const catalog = new TuiSessionCatalog(options.dataDir);
  try {
    for (const path of paths) {
      catalog.deletePath(path);
    }
  } finally {
    catalog.close();
  }
}

export function listCatalogedLocalSessions(
  knownPiSessions: KnownLocalSessions,
  options: { dataDir: string },
): LocalSessionCatalogSnapshot {
  const catalog = new TuiSessionCatalog(options.dataDir);
  try {
    const lastScannedAt = catalog.getLastScannedAt();
    return {
      sessions: catalog
        .listRows()
        .filter((row) => !isKnownLocalSession(row, knownPiSessions))
        .map(rowToLocalSession),
      ...(lastScannedAt !== undefined ? { lastScannedAt } : {}),
    };
  } finally {
    catalog.close();
  }
}

/**
 * Discover all local pi sessions.
 *
 * Stats every JSONL file under the configured pi sessions root but only reads
 * file contents when the file is new or its mtime changed since the last call.
 * Known oppi-managed files are filtered out.
 *
 * Enumeration is async so callers (including fire-and-forget catalog refresh)
 * do not block the event loop on large developer home trees during the first
 * tick of the discovery promise.
 *
 * @param knownPiSessionFiles Set of piSessionFile paths already managed by oppi
 */
export async function discoverLocalSessions(
  knownPiSessions?: KnownLocalSessions,
  options: { dataDir?: string } = {},
): Promise<LocalSession[]> {
  const sessionsRoot = resolvePiSessionsRoot();
  if (!existsSync(sessionsRoot)) {
    return [];
  }

  // Enumerate all JSONL files across CWD directories without sync readdir storms.
  let topLevel: string[];
  try {
    topLevel = await readdir(sessionsRoot);
  } catch {
    return [];
  }

  const cwdDirs: string[] = [];
  const ENUM_BATCH_SIZE = 32;
  for (let i = 0; i < topLevel.length; i += ENUM_BATCH_SIZE) {
    const batch = topLevel.slice(i, i + ENUM_BATCH_SIZE);
    const batchDirs = await Promise.all(
      batch.map(async (name) => {
        const full = join(sessionsRoot, name);
        try {
          const entries = await readdir(full);
          return entries.some((f) => f.endsWith(".jsonl")) ? full : null;
        } catch {
          return null;
        }
      }),
    );
    for (const dir of batchDirs) {
      if (dir) cwdDirs.push(dir);
    }
  }

  // Collect all file paths + resolve symlinks
  const allFiles: string[] = [];
  for (const dir of cwdDirs) {
    try {
      const entries = await readdir(dir);
      for (const f of entries) {
        if (!f.endsWith(".jsonl")) continue;
        try {
          allFiles.push(realpathSync(join(dir, f)));
        } catch {
          // skip unresolvable symlinks
        }
      }
    } catch {
      continue;
    }
  }

  // Track which paths are still on disk (to prune stale cache entries)
  const livePaths = new Set(allFiles);

  // Stat all files in parallel — this is fast (~1ms for hundreds of files)
  const statResults = await Promise.all(
    allFiles.map(async (realFile) => {
      try {
        const s = await stat(realFile);
        return { path: realFile, size: s.size, mtimeMs: s.mtimeMs };
      } catch {
        return null;
      }
    }),
  );

  if (options.dataDir) {
    const catalog = new TuiSessionCatalog(options.dataDir);
    try {
      const cachedByPath = catalog.rowsByPath();
      const needsRead: { path: string; size: number; mtimeMs: number }[] = [];
      for (const s of statResults) {
        if (!s) continue;
        const cached = cachedByPath.get(s.path);
        if (!cached || cached.mtime_ms !== s.mtimeMs || cached.size_bytes !== s.size) {
          needsRead.push(s);
        }
      }

      await refreshTuiSessionCatalog(catalog, needsRead);
      catalog.deleteMissing(livePaths);
      catalog.setLastScannedAt(Date.now());

      return catalog
        .listRows()
        .filter((row) => !isKnownLocalSession(row, knownPiSessions))
        .map(rowToLocalSession);
    } finally {
      catalog.close();
    }
  }

  // For files with changed/new mtime, read metadata in parallel batches.
  // This in-memory path is retained for tests and callers without a dataDir.
  const needsRead: { path: string; size: number; mtimeMs: number }[] = [];
  for (const s of statResults) {
    if (!s) continue;
    const cached = metadataCache.get(s.path);
    if (!cached || cached.mtimeMs !== s.mtimeMs) {
      needsRead.push(s);
    }
  }

  await refreshInMemoryLocalSessionCache(needsRead);

  // Prune entries for deleted files
  for (const key of metadataCache.keys()) {
    if (!livePaths.has(key)) metadataCache.delete(key);
  }

  // Collect results, filtering out known Oppi-managed identities.
  const results: LocalSession[] = [];
  for (const { session } of metadataCache.values()) {
    if (isKnownLocalSessionValue(session, knownPiSessions)) continue;
    results.push(session);
  }

  results.sort((a, b) => b.lastModified - a.lastModified);
  return results;
}
