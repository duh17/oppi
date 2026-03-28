import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { generateId } from "../id.js";
import type { Session, SessionChangeStats } from "../types.js";
import type { ConfigStore } from "./config-store.js";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Backfill cache token fields for sessions persisted before cacheRead/cacheWrite existed. */
function backfillTokens(session: Session): void {
  if (session.tokens && !("cacheRead" in session.tokens)) {
    (session.tokens as Record<string, number>).cacheRead = 0;
    (session.tokens as Record<string, number>).cacheWrite = 0;
  }
}

/**
 * Strip internal bookkeeping fields from changeStats before caching.
 *
 * `_fileLineCounts` and `_sessionCreatedFiles` are only needed during
 * active sessions (for accurate line delta computation). They can grow
 * large (hundreds of file paths) and are the main driver of per-session
 * memory bloat. Stripping them from the cache keeps each entry at ~2 KB
 * instead of 50-100 KB for heavy sessions.
 *
 * The full data is always written to disk and restored when needed.
 */
function stripInternalFields(session: Session): Session {
  const stats = session.changeStats;
  if (!stats?._fileLineCounts && !stats?._sessionCreatedFiles) {
    return session;
  }

  const { _fileLineCounts: _, _sessionCreatedFiles: __, ...cleanStats } = stats;
  return { ...session, changeStats: cleanStats as SessionChangeStats };
}

/**
 * Before writing to disk, restore internal fields that may have been
 * stripped from the cached copy. Reads the existing disk file only when
 * the session has changeStats but is missing the internal fields (i.e.
 * it came from the stripped cache, not from an active session).
 */
function restoreInternalFields(session: Session, sessionPath: string): Session {
  // Active sessions still have _fileLineCounts — nothing to restore
  if (session.changeStats?._fileLineCounts) return session;
  // No change stats at all — nothing to restore
  if (!session.changeStats || session.changeStats.filesChanged === 0) return session;

  // Read the current disk version to recover internal fields
  try {
    if (!existsSync(sessionPath)) return session;
    const raw = JSON.parse(readFileSync(sessionPath, "utf-8")) as unknown;
    if (!isRecord(raw)) return session;
    const disk = raw.session as Session | undefined;
    if (!disk?.changeStats?._fileLineCounts) return session;

    return {
      ...session,
      changeStats: {
        ...session.changeStats,
        _fileLineCounts: disk.changeStats._fileLineCounts,
        _sessionCreatedFiles: disk.changeStats._sessionCreatedFiles,
      },
    };
  } catch {
    return session;
  }
}

export class SessionStore {
  /**
   * In-memory session cache. Populated lazily on first read, updated on
   * every write. Internal bookkeeping fields (_fileLineCounts, etc.) are
   * stripped from cached entries to bound per-session memory to ~2 KB.
   */
  private cache: Map<string, Session> | null = null;

  constructor(private readonly configStore: ConfigStore) {}

  private getSessionPath(sessionId: string): string {
    return join(this.configStore.getSessionsDir(), `${sessionId}.json`);
  }

  /** Populate the cache from disk. Called once on first access. */
  private ensureCache(): Map<string, Session> {
    if (this.cache) return this.cache;

    this.cache = new Map();
    const baseDir = this.configStore.getSessionsDir();
    if (!existsSync(baseDir)) return this.cache;

    for (const file of readdirSync(baseDir)) {
      // Only load <sessionId>.json — skip auxiliary files like *.annotations.json
      if (!file.endsWith(".json")) continue;
      if (file.indexOf(".") !== file.length - 5) continue;

      const path = join(baseDir, file);
      try {
        const raw = JSON.parse(readFileSync(path, "utf-8")) as unknown;
        if (!isRecord(raw)) {
          console.error(`[storage] Corrupt session file ${path}, skipping`);
          continue;
        }

        const session = raw.session as Session | undefined;
        if (!session) {
          console.error(`[storage] Corrupt session file ${path}, skipping`);
          continue;
        }

        backfillTokens(session);
        this.cache.set(session.id, stripInternalFields(session));
      } catch {
        console.error(`[storage] Corrupt session file ${path}, skipping`);
      }
    }

    return this.cache;
  }

  createSession(name?: string, model?: string): Session {
    const id = generateId(8);

    const session: Session = {
      id,
      name,
      status: "starting",
      createdAt: Date.now(),
      lastActivity: Date.now(),
      model: model || this.configStore.getConfig().defaultModel,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };

    this.saveSession(session);
    return session;
  }

  saveSession(session: Session): void {
    const path = this.getSessionPath(session.id);
    const dir = dirname(path);

    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true, mode: 0o700 });
    }

    // Write full data to disk — restore internal fields if the session
    // came from the stripped cache (e.g. stopped session re-saved by a route)
    const toWrite = restoreInternalFields(session, path);
    const payload = JSON.stringify({ session: toWrite }, null, 2);
    writeFileSync(path, payload, { mode: 0o600 });

    // Cache a lightweight copy (internal bookkeeping fields stripped)
    this.ensureCache().set(session.id, stripInternalFields(session));
  }

  getSession(sessionId: string): Session | undefined {
    const cache = this.ensureCache();
    const cached = cache.get(sessionId);
    if (cached) return cached;

    // Fallback: file may have been written externally (unlikely but safe)
    const path = this.getSessionPath(sessionId);
    if (!existsSync(path)) return undefined;

    try {
      const raw = JSON.parse(readFileSync(path, "utf-8")) as unknown;
      if (!isRecord(raw)) return undefined;
      const session = raw.session as Session | undefined;
      if (!session) return undefined;
      backfillTokens(session);
      cache.set(session.id, stripInternalFields(session));
      return cache.get(sessionId);
    } catch {
      return undefined;
    }
  }

  listSessions(): Session[] {
    const cache = this.ensureCache();
    const sessions = Array.from(cache.values());
    // Sort by last activity (most recent first)
    return sessions.sort((a, b) => b.lastActivity - a.lastActivity);
  }

  deleteSession(sessionId: string): boolean {
    const path = this.getSessionPath(sessionId);
    if (!existsSync(path)) return false;

    rmSync(path);
    this.ensureCache().delete(sessionId);
    return true;
  }
}
