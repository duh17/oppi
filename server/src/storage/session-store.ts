import {
  closeSync,
  existsSync,
  fstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { generateId } from "../id.js";
import { createLogger } from "../logger.js";
import { safeErrorMessage } from "../log-utils.js";
import { estimateUsageCostFromModel, normalizePiUsage } from "../token-usage.js";
import type { Session, SessionChangeStats } from "../types.js";
import type { ConfigStore } from "./config-store.js";
import type {
  WorkspaceSessionSnapshotListOptions,
  WorkspaceSessionSnapshotListResult,
} from "./session-dao.js";

const log = createLogger({ base: { component: "session_store" } });

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

const TRACE_TAIL_INITIAL_BYTES = 256 * 1024;
const TRACE_TAIL_MAX_BYTES = 2 * 1024 * 1024;

function totalTokenUsage(tokens: {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
}): number {
  return tokens.input + tokens.output + tokens.cacheRead + tokens.cacheWrite;
}

/**
 * Recover the last non-zero context snapshot from the pi JSONL trace.
 *
 * Some stopped sessions end with a synthetic aborted assistant message whose
 * usage is all zeros. Older servers persisted that zero snapshot, clobbering
 * the previous real context usage. Scan backward through the trace tail and
 * keep the last non-zero assistant usage instead.
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

function compareSessionsByActivity(a: Session, b: Session): number {
  if (b.lastActivity !== a.lastActivity) {
    return b.lastActivity - a.lastActivity;
  }
  return a.id.localeCompare(b.id);
}

function normalizePositiveInteger(value: number | undefined): number | undefined {
  if (value === undefined || !Number.isFinite(value)) {
    return undefined;
  }
  const normalized = Math.floor(value);
  return normalized > 0 ? normalized : undefined;
}

function normalizeLimit(value: number | undefined, maxLimit: number): number {
  if (value === undefined || !Number.isFinite(value)) {
    return 0;
  }
  const normalized = Math.floor(value);
  if (normalized <= 0) {
    return 0;
  }
  return Math.min(normalized, maxLimit);
}

function sessionMatchesSnapshotFilters(
  session: Session,
  filters: {
    cutoffMs?: number;
    status?: Session["status"];
    beforeLastActivity?: number;
    beforeSessionId?: string;
  },
): boolean {
  if (filters.cutoffMs !== undefined && session.status === "stopped") {
    if (session.lastActivity < filters.cutoffMs) {
      return false;
    }
  }

  if (filters.status && session.status !== filters.status) {
    return false;
  }

  if (filters.beforeLastActivity !== undefined && Number.isFinite(filters.beforeLastActivity)) {
    return (
      session.lastActivity < filters.beforeLastActivity ||
      (filters.beforeSessionId !== undefined &&
        session.lastActivity === filters.beforeLastActivity &&
        session.id > filters.beforeSessionId)
    );
  }

  return true;
}

function includeWorkspaceAncestors(
  workspaceId: string,
  sessions: Session[],
  byId: Map<string, Session>,
): Session[] {
  const resultById = new Map(sessions.map((session) => [session.id, session]));
  const pending = sessions.flatMap((session) =>
    session.parentSessionId ? [session.parentSessionId] : [],
  );
  let remainingLookups = 256;

  while (pending.length > 0 && remainingLookups > 0) {
    remainingLookups -= 1;
    const parentId = pending.pop();
    if (!parentId || resultById.has(parentId)) {
      continue;
    }

    const parent = byId.get(parentId);
    if (!parent || parent.workspaceId !== workspaceId) {
      continue;
    }

    resultById.set(parent.id, parent);
    if (parent.parentSessionId) {
      pending.push(parent.parentSessionId);
    }
  }

  return Array.from(resultById.values()).sort(compareSessionsByActivity);
}

export class SessionStore {
  /**
   * In-memory session cache. Populated lazily on first read, updated on
   * every write. Internal bookkeeping fields (_fileLineCounts, etc.) are
   * stripped from cached entries to bound per-session memory to ~2 KB.
   */
  private cache: Map<string, Session> | null = null;
  private loadFailures: string[] = [];

  constructor(private readonly configStore: ConfigStore) {}

  private getSessionPath(sessionId: string): string {
    return join(this.configStore.getSessionsDir(), `${sessionId}.json`);
  }

  /** Populate the cache from disk. Called once on first access. */
  private ensureCache(): Map<string, Session> {
    if (this.cache) return this.cache;

    this.cache = new Map();
    this.loadFailures = [];
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
          log.error("session_store.session_file.invalid", {
            sessionFilePath: path,
            reason: "top_level_not_object",
          });
          this.loadFailures.push(path);
          continue;
        }

        const session = raw.session as Session | undefined;
        if (!session) {
          log.error("session_store.session_file.invalid", {
            sessionFilePath: path,
            reason: "missing_session_payload",
          });
          this.loadFailures.push(path);
          continue;
        }

        backfillTokens(session);
        backfillCostFromTokens(session);
        backfillContextTokensFromTrace(session);
        this.cache.set(session.id, stripInternalFields(session));
      } catch (err: unknown) {
        log.error("session_store.session_file_parse.failed", {
          sessionFilePath: path,
          error: safeErrorMessage(err),
        });
        this.loadFailures.push(path);
      }
    }

    return this.cache;
  }

  getLoadFailures(): string[] {
    this.ensureCache();
    return [...this.loadFailures];
  }

  createSession(name?: string, model?: string): Session {
    const id = generateId(8);

    const session: Session = {
      id,
      name,
      // A freshly created session with no prompt is idle, not mid-startup.
      // `starting` is reserved for actual SDK startup in SessionStartCoordinator.
      status: "ready",
      createdAt: Date.now(),
      lastActivity: Date.now(),
      ...(model ? { model } : {}),
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
      backfillCostFromTokens(session);
      backfillContextTokensFromTrace(session);
      cache.set(session.id, stripInternalFields(session));
      return cache.get(sessionId);
    } catch {
      return undefined;
    }
  }

  listSessions(): Session[] {
    const cache = this.ensureCache();
    const sessions = Array.from(cache.values());
    return sessions.sort(compareSessionsByActivity);
  }

  listSessionsByWorkspace(workspaceId: string): Session[] {
    const cache = this.ensureCache();
    const sessions: Session[] = [];
    for (const session of cache.values()) {
      if (session.workspaceId === workspaceId) {
        sessions.push(session);
      }
    }
    return sessions.sort(compareSessionsByActivity);
  }

  listWorkspaceSessionSnapshots(
    workspaceId: string,
    options: WorkspaceSessionSnapshotListOptions = {},
  ): WorkspaceSessionSnapshotListResult {
    const nowMs = options.nowMs ?? Date.now();
    const recentDays = normalizePositiveInteger(options.recentDays);
    const cutoffMs = recentDays ? nowMs - recentDays * 86_400_000 : undefined;
    const appliedLimit = normalizeLimit(options.limit, options.maxLimit ?? 500);
    const beforeLastActivity = Number.isFinite(options.beforeLastActivity)
      ? options.beforeLastActivity
      : undefined;

    const allSessions = this.listSessionsByWorkspace(workspaceId);
    const totalCount = allSessions.length;
    const byId = new Map(allSessions.map((session) => [session.id, session]));
    const filtered = allSessions.filter((session) =>
      sessionMatchesSnapshotFilters(session, {
        cutoffMs,
        status: options.status,
        beforeLastActivity,
        beforeSessionId: options.beforeSessionId,
      }),
    );
    const page = appliedLimit > 0 ? filtered.slice(0, appliedLimit) : filtered;
    const sessions = includeWorkspaceAncestors(workspaceId, page, byId);

    return {
      sessions,
      totalCount,
      filteredCount: filtered.length,
      remainingCount: appliedLimit > 0 ? Math.max(0, filtered.length - page.length) : 0,
      ...(cutoffMs !== undefined ? { cutoffMs } : {}),
      appliedLimit,
    };
  }

  deleteSession(sessionId: string): boolean {
    const path = this.getSessionPath(sessionId);
    if (!existsSync(path)) return false;

    rmSync(path);
    this.ensureCache().delete(sessionId);
    return true;
  }
}
