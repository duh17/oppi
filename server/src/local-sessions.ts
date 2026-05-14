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
  readdirSync,
  openSync,
  readSync,
  closeSync,
  realpathSync,
} from "node:fs";
import { stat, readdir } from "node:fs/promises";
import { join, resolve } from "node:path";
import { homedir } from "node:os";
import { openDatabase, type SqliteDatabase } from "./sqlite-compat.js";
import type { LocalSession } from "./types.js";

/** Fixed root of pi agent sessions. */
const PI_SESSIONS_ROOT = join(homedir(), ".pi", "agent", "sessions");

/**
 * Return the canonical pi sessions root, resolving symlinks.
 * Used for path confinement validation.
 */
export function getPiSessionsRoot(): string {
  try {
    return realpathSync(PI_SESSIONS_ROOT);
  } catch {
    return PI_SESSIONS_ROOT;
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
 * Performance: reads only the first 16KB of the file (enough for
 * header + first few events) rather than the entire file. For message
 * count, uses file size as a heuristic (actual count requires full read).
 */
async function extractSessionMetadata(
  filePath: string,
  fileSize: number,
): Promise<{ name?: string; firstMessage?: string; model?: string; messageCount: number }> {
  try {
    // Read first 16KB — enough for session header, model_change, session_info, first message
    const fd = openSync(filePath, "r");
    const chunkSize = Math.min(fileSize, 16384);
    const buffer = Buffer.alloc(chunkSize);
    const bytesRead = readSync(fd, buffer, 0, chunkSize, 0);
    closeSync(fd);

    const chunk = buffer.toString("utf8", 0, bytesRead);
    const lines = chunk.split("\n");

    let name: string | undefined;
    let firstMessage: string | undefined;
    let model: string | undefined;
    let messageCount = 0;

    for (const line of lines) {
      if (!line.trim()) continue;

      let entry: Record<string, unknown>;
      try {
        entry = JSON.parse(line) as Record<string, unknown>;
      } catch {
        continue;
      }

      // Session name
      if (entry.type === "session_info") {
        const n = entry.name;
        if (typeof n === "string" && n.trim().length > 0) {
          name = n.trim();
        }
      }

      // Model (use first found in chunk)
      if (entry.type === "model_change" && !model) {
        const provider = entry.provider;
        const modelId = entry.modelId;
        if (typeof provider === "string" && typeof modelId === "string") {
          model = modelId.startsWith(`${provider}/`) ? modelId : `${provider}/${modelId}`;
        }
      }

      // Messages
      if (entry.type === "message") {
        const msg = entry.message as Record<string, unknown> | undefined;
        if (msg && typeof msg.role === "string") {
          if (msg.role === "user" || msg.role === "assistant") {
            messageCount++;
          }
          if (!firstMessage && msg.role === "user") {
            const content = msg.content;
            if (typeof content === "string") {
              firstMessage = content.slice(0, 200);
            } else if (Array.isArray(content)) {
              const text = content.find(
                (c: unknown) =>
                  typeof c === "object" &&
                  c !== null &&
                  (c as Record<string, unknown>).type === "text",
              ) as { text?: string } | undefined;
              if (text?.text) {
                firstMessage = text.text.slice(0, 200);
              }
            }
          }
        }
      }

      // Early exit once we have everything we need from the head
      if (firstMessage && model) break;
    }

    // Estimate message count from file size if we only read a chunk
    // Average JSONL line for a message event is ~1-2KB
    if (fileSize > chunkSize) {
      const avgLineSize = chunkSize / Math.max(lines.length, 1);
      const estimatedTotalLines = Math.round(fileSize / avgLineSize);
      // Roughly 40% of lines are message events in a typical session
      messageCount = Math.max(messageCount, Math.round(estimatedTotalLines * 0.4));
    }

    return { name, firstMessage, model, messageCount };
  } catch {
    return { messageCount: 0 };
  }
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
  is_subagent: number;
}

export interface LocalSessionCatalogSnapshot {
  sessions: LocalSession[];
  lastScannedAt?: number;
}

class TuiSessionCatalog {
  private readonly db: SqliteDatabase;

  constructor(dataDir: string) {
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

  upsert(session: LocalSession, sizeBytes: number, mtimeMs: number, isSubagent: boolean): void {
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
          is_subagent,
          updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
          is_subagent = excluded.is_subagent,
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
        isSubagent ? 1 : 0,
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
        is_subagent INTEGER NOT NULL DEFAULT 0,
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
        catalog.upsert(session, size, mtimeMs, isSubagentLocalSession(session));
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

function isSubagentPrompt(text: string | undefined): boolean {
  return /^\[Subagent profile: [^\]]+\]\s*\n/.test(text?.trimStart() ?? "");
}

function isSubagentLocalSession(session: LocalSession): boolean {
  return isSubagentPrompt(session.firstMessage) || isSubagentPrompt(session.name);
}

/** Invalidate the cache (call after importing a session). */
export function invalidateLocalSessionsCache(): void {
  metadataCache.clear();
}

export function listCatalogedLocalSessions(
  knownPiSessionFiles: Set<string> | undefined,
  options: { dataDir: string },
): LocalSessionCatalogSnapshot {
  const catalog = new TuiSessionCatalog(options.dataDir);
  try {
    const lastScannedAt = catalog.getLastScannedAt();
    return {
      sessions: catalog
        .listRows()
        .filter((row) => row.is_subagent === 0 && !knownPiSessionFiles?.has(row.path))
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
 * Stats every JSONL file under ~/.pi/agent/sessions/ but only reads
 * file contents when the file is new or its mtime changed since the
 * last call. Known oppi-managed files are filtered out.
 *
 * @param knownPiSessionFiles Set of piSessionFile paths already managed by oppi
 */
export async function discoverLocalSessions(
  knownPiSessionFiles?: Set<string>,
  options: { dataDir?: string } = {},
): Promise<LocalSession[]> {
  if (!existsSync(PI_SESSIONS_ROOT)) {
    return [];
  }

  // Enumerate all JSONL files across CWD directories
  let cwdDirs: string[];
  try {
    cwdDirs = readdirSync(PI_SESSIONS_ROOT)
      .filter((name) => {
        try {
          const full = join(PI_SESSIONS_ROOT, name);
          return existsSync(full) && readdirSync(full).some((f) => f.endsWith(".jsonl"));
        } catch {
          return false;
        }
      })
      .map((name) => join(PI_SESSIONS_ROOT, name));
  } catch {
    return [];
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
        .filter((row) => row.is_subagent === 0 && !knownPiSessionFiles?.has(row.path))
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

  // Collect results, filtering out known oppi-managed files
  const results: LocalSession[] = [];
  for (const { session } of metadataCache.values()) {
    if (knownPiSessionFiles?.has(session.path)) continue;
    if (isSubagentLocalSession(session)) continue;
    results.push(session);
  }

  results.sort((a, b) => b.lastModified - a.lastModified);
  return results;
}
