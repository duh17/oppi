import {
  collectKnownLocalSessionIdentities,
  discoverLocalSessions,
  listCatalogedLocalSessions,
  validateCwdAlignment,
  type LocalSessionCatalogSnapshot,
} from "./local-sessions.js";
import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import { isPiTuiTaskRecordSession } from "./pi-tui-session-classification.js";
import type { SessionRuntimes } from "./runtime-router.js";
import {
  pendingBlockingUIRequestCount,
  type PendingUIRequestProvider,
} from "./session-attention.js";
import { buildSessionSummary } from "./session-summary.js";
import { isDeclaredControlSession } from "./control-session.js";
import type { Storage } from "./storage.js";
import type { WorkspaceStoppedTimeBucketSnapshot } from "./storage/session-dao.js";
import type { LocalSession, Session, SessionSummary, Workspace } from "./types.js";
import { resolveWorkspaceWorktree } from "./worktrees.js";

const LOCAL_SESSION_CATALOG_MAX_AGE_MS = 60_000;

const log = createLogger({ base: { component: "session_list" } });

export type SessionStatusFilter = "active" | "stopped";

export type ManagedSessionListRow = SessionSummary & {
  pendingAskCount: number;
};

export type TuiSessionListRow = {
  id: string;
  source: "tui";
  status: "stopped";
  workspaceId: string;
  workspaceName?: string;
  name?: string;
  createdAt: number;
  lastActivity: number;
  lastModified: number;
  model?: string;
  messageCount: number;
  tokens: Session["tokens"];
  cost: number;
  firstMessage?: string;
  piSessionId: string;
  path: string;
  cwd: string;
  pendingAskCount: 0;
};

export type SessionListRow = ManagedSessionListRow | TuiSessionListRow;

export type SessionListArchiveBucket = {
  bucketId: string;
  bucketKind: "day" | "month";
  startMs: number;
  endMs: number;
  itemCount: number;
  managedStoppedCount: number;
  importableLocalCount: number;
  latestActivity?: number;
};

export interface RecentWorkspaceSessionSummariesResult {
  sessions: ManagedSessionListRow[];
}

export interface WorkspaceSessionCollectionResult {
  workspaceId: string;
  sinceMs?: number;
  untilMs?: number;
  serverNow: number;
  active?: SessionListRow[];
  stopped?: SessionListRow[];
}

export interface WorkspaceStoppedSessionBucketsResult {
  workspaceId: string;
  status: "stopped";
  beforeMs: number;
  serverNow: number;
  buckets: SessionListArchiveBucket[];
}

export interface SessionListServiceDeps {
  storage: Pick<
    Storage,
    | "getDataDir"
    | "listAllWorkspaceSessionSnapshots"
    | "listRecentWorkspaceSessionSnapshots"
    | "listSessions"
    | "listStoppedWorkspaceTimeRangeSessionSnapshots"
    | "listWorkspaceStoppedTimeBuckets"
    | "listWorkspaces"
  >;
  sessionRuntimes: Pick<
    SessionRuntimes,
    "getActiveSession" | "getActiveSessionIds" | "getPendingUIRequestMessages"
  >;
  ensureSessionContextWindow: (session: Session) => Session;
}

/**
 * Application service for session list/read-model policy.
 *
 * Transport adapters pass parsed query parameters here instead of shaping rows,
 * merging live runtime snapshots, or joining attention counts themselves.
 */
export class SessionListService {
  constructor(private readonly deps: SessionListServiceDeps) {}

  listRecentWorkspaceSessionSummaries(params: {
    recentDays: number;
    piSessionId?: string;
    nowMs?: number;
  }): RecentWorkspaceSessionSummariesResult {
    const serverNow = params.nowMs ?? Date.now();
    const workspaceSessions = this.deps.storage
      .listWorkspaces()
      .flatMap((workspace) =>
        (params.recentDays > 0
          ? this.deps.storage.listRecentWorkspaceSessionSnapshots(
              workspace.id,
              params.recentDays,
              serverNow,
            )
          : this.deps.storage.listAllWorkspaceSessionSnapshots(workspace.id)
        ).filter(isOpenableManagedListSession),
      );
    const cutoffMs = params.recentDays > 0 ? serverNow - params.recentDays * 86_400_000 : undefined;
    const controlSessions = this.deps.storage
      .listSessions()
      .filter(
        (session) =>
          isDeclaredControlSession(session) &&
          isOpenableManagedListSession(session) &&
          (cutoffMs === undefined || session.lastActivity >= cutoffMs),
      );
    const projectedSessions = [...workspaceSessions, ...controlSessions];

    let sessions = this.buildManagedSessionListRows(
      mergeActiveSessionsAcrossWorkspaces(
        this.deps.sessionRuntimes,
        projectedSessions,
        cutoffMs === undefined ? {} : { cutoffMs },
      ),
      collectPendingAttentionCounts(this.deps.sessionRuntimes),
    );

    if (params.piSessionId) {
      sessions = sessions.filter((session) => session.piSessionId === params.piSessionId);
    }

    return { sessions };
  }

  listWorkspaceSessionRows(params: {
    workspace: Workspace;
    statuses: ReadonlySet<SessionStatusFilter>;
    timeRange?: { sinceMs: number; untilMs: number };
    worktreeId?: string;
    nowMs?: number;
  }): WorkspaceSessionCollectionResult {
    const serverNow = params.nowMs ?? Date.now();
    const attention = collectPendingAttentionCounts(this.deps.sessionRuntimes);
    const response: WorkspaceSessionCollectionResult = {
      workspaceId: params.workspace.id,
      serverNow,
    };

    if (params.timeRange) {
      response.sinceMs = params.timeRange.sinceMs;
      response.untilMs = params.timeRange.untilMs;
    }

    if (params.statuses.has("active")) {
      response.active = this.listWorkspaceActiveSessionRows(
        params.workspace.id,
        attention,
        params.worktreeId,
      );
    }

    if (params.statuses.has("stopped") && params.timeRange) {
      response.stopped = this.listWorkspaceStoppedSessionRows(
        params.workspace,
        params.timeRange,
        attention,
        serverNow,
        params.worktreeId,
      );
    }

    return response;
  }

  listWorkspaceStoppedSessionBuckets(params: {
    workspace: Workspace;
    beforeMs: number;
    worktreeId?: string;
    nowMs?: number;
  }): WorkspaceStoppedSessionBucketsResult {
    const serverNow = params.nowMs ?? Date.now();
    const importableSnapshot = this.listWorkspaceImportableSessions(
      params.workspace,
      params.worktreeId,
    );
    this.refreshLocalSessionCatalogIfStale(importableSnapshot.lastScannedAt, serverNow);
    const olderImportableSessions = importableSnapshot.sessions
      .filter((session) => session.lastModified < params.beforeMs)
      .sort((lhs, rhs) => rhs.lastModified - lhs.lastModified);
    const buckets = mergeWorkspaceArchiveBuckets(
      this.deps.storage.listWorkspaceStoppedTimeBuckets(
        params.workspace.id,
        params.beforeMs,
        serverNow,
        params.worktreeId,
      ),
      olderImportableSessions,
      serverNow,
    );

    return {
      workspaceId: params.workspace.id,
      status: "stopped",
      beforeMs: params.beforeMs,
      serverNow,
      buckets,
    };
  }

  private listWorkspaceActiveSessionRows(
    workspaceId: string,
    attention: PendingAttentionCounts,
    worktreeId?: string,
  ): ManagedSessionListRow[] {
    const sessions = mergeActiveWorkspaceSessions(
      this.deps.sessionRuntimes,
      this.deps.storage.listAllWorkspaceSessionSnapshots(workspaceId, worktreeId),
      workspaceId,
      { worktreeId },
    )
      .filter(isOpenableManagedListSession)
      .filter(isActiveListSession);
    return this.buildManagedSessionListRows(sessions, attention).sort(compareActiveSessionListRows);
  }

  private listWorkspaceStoppedSessionRows(
    workspace: Workspace,
    timeRange: { sinceMs: number; untilMs: number },
    attention: PendingAttentionCounts,
    serverNow: number,
    worktreeId?: string,
  ): SessionListRow[] {
    const managed = this.deps.storage
      .listStoppedWorkspaceTimeRangeSessionSnapshots(
        workspace.id,
        timeRange.sinceMs,
        timeRange.untilMs,
        worktreeId,
      )
      .filter(isOpenableManagedListSession)
      .filter(
        (session) =>
          session.status === "stopped" &&
          session.lastActivity >= timeRange.sinceMs &&
          session.lastActivity < timeRange.untilMs,
      );
    const managedRows = this.buildManagedSessionListRows(managed, attention);

    const importableSnapshot = this.listWorkspaceImportableSessions(workspace, worktreeId);
    this.refreshLocalSessionCatalogIfStale(importableSnapshot.lastScannedAt, serverNow);
    const importableSplit = splitImportableSessionsByRange(
      importableSnapshot.sessions,
      timeRange.sinceMs,
      timeRange.untilMs,
    );
    return [
      ...managedRows,
      ...buildTuiSessionListRows(workspace, importableSplit.visibleSessions),
    ].sort(compareStoppedSessionListRows);
  }

  private buildManagedSessionListRows(
    sessions: Session[],
    attention: PendingAttentionCounts,
  ): ManagedSessionListRow[] {
    return sessions.map((session) => {
      const summary = buildSessionSummary(this.deps.ensureSessionContextWindow(session));
      return {
        ...summary,
        pendingAskCount: attention.asks.get(summary.id) ?? 0,
      };
    });
  }

  private listWorkspaceImportableSessions(
    workspace: Workspace,
    worktreeId?: string,
  ): LocalSessionCatalogSnapshot {
    const knownPiSessionIdentities = this.collectKnownPiSessionIdentities();
    const snapshot = listCatalogedLocalSessions(knownPiSessionIdentities, {
      dataDir: this.deps.storage.getDataDir(),
    });
    const hostMount = worktreeId
      ? resolveWorkspaceWorktree(workspace, worktreeId, {
          dataDir: this.deps.storage.getDataDir(),
        })?.path
      : workspace.hostMount;
    if (!hostMount) {
      return { ...snapshot, sessions: [] };
    }

    return {
      ...snapshot,
      sessions: snapshot.sessions.filter((session) => validateCwdAlignment(session.cwd, hostMount)),
    };
  }

  private refreshLocalSessionCatalogIfStale(
    lastScannedAt: number | undefined,
    nowMs: number,
  ): void {
    if (lastScannedAt !== undefined && nowMs - lastScannedAt < LOCAL_SESSION_CATALOG_MAX_AGE_MS) {
      return;
    }

    const knownPiSessionIdentities = this.collectKnownPiSessionIdentities();
    void discoverLocalSessions(knownPiSessionIdentities, {
      dataDir: this.deps.storage.getDataDir(),
    }).catch((error: unknown) => {
      log.warn("local_session_catalog.refresh_failed", {
        error: safeErrorMessage(error),
      });
    });
  }

  private collectKnownPiSessionIdentities(): { files: Set<string>; piSessionIds: Set<string> } {
    return collectKnownLocalSessionIdentities(this.deps.storage.listSessions()) as {
      files: Set<string>;
      piSessionIds: Set<string>;
    };
  }
}

interface PendingAttentionCounts {
  asks: Map<string, number>;
}

function sessionMatchesWorkspaceListFilters(
  session: Session,
  filters: {
    cutoffMs?: number;
    untilMs?: number;
    worktreeId?: string;
  },
): boolean {
  if (filters.cutoffMs !== undefined && session.status === "stopped") {
    if (session.lastActivity < filters.cutoffMs) {
      return false;
    }
  }

  if (filters.untilMs !== undefined && session.status === "stopped") {
    if (session.lastActivity >= filters.untilMs) {
      return false;
    }
  }

  if (filters.worktreeId && (session.worktreeId ?? "main") !== filters.worktreeId) {
    return false;
  }

  return true;
}

function compareWorkspaceListSessions(a: Session, b: Session): number {
  if (b.lastActivity !== a.lastActivity) {
    return b.lastActivity - a.lastActivity;
  }
  return a.id.localeCompare(b.id);
}

function isOpenableManagedListSession(session: Session): boolean {
  return !isPiTuiTaskRecordSession(session);
}

function isActiveListSession(session: Session): boolean {
  return session.status !== "stopped";
}

function addCount(map: Map<string, number>, key: string, count: number): void {
  if (count <= 0) return;
  map.set(key, (map.get(key) ?? 0) + count);
}

function collectPendingAttentionCounts(provider: PendingUIRequestProvider): PendingAttentionCounts {
  const asks = new Map<string, number>();
  for (const sessionId of provider.getActiveSessionIds()) {
    addCount(asks, sessionId, pendingBlockingUIRequestCount(provider, sessionId));
  }

  return { asks };
}

function mergeActiveSessionsAcrossWorkspaces(
  sessionRuntimes: Pick<SessionRuntimes, "getActiveSession" | "getActiveSessionIds">,
  projectedSessions: Session[],
  filters: {
    cutoffMs?: number;
    untilMs?: number;
    worktreeId?: string;
  },
): Session[] {
  const byId = new Map(projectedSessions.map((session) => [session.id, session]));
  for (const activeSessionId of sessionRuntimes.getActiveSessionIds()) {
    const active = sessionRuntimes.getActiveSession(activeSessionId);
    if (!active || (!active.workspaceId && !isDeclaredControlSession(active))) {
      continue;
    }
    if (!sessionMatchesWorkspaceListFilters(active, filters)) {
      continue;
    }
    byId.set(active.id, active);
  }
  return Array.from(byId.values()).sort(compareWorkspaceListSessions);
}

function mergeActiveWorkspaceSessions(
  sessionRuntimes: Pick<SessionRuntimes, "getActiveSession" | "getActiveSessionIds">,
  projectedSessions: Session[],
  workspaceId: string,
  filters: {
    cutoffMs?: number;
    untilMs?: number;
    worktreeId?: string;
  },
): Session[] {
  const byId = new Map(projectedSessions.map((session) => [session.id, session]));
  for (const activeSessionId of sessionRuntimes.getActiveSessionIds()) {
    const active = sessionRuntimes.getActiveSession(activeSessionId);
    if (!active || active.workspaceId !== workspaceId) {
      continue;
    }
    if (!sessionMatchesWorkspaceListFilters(active, filters)) {
      continue;
    }
    byId.set(active.id, active);
  }
  return Array.from(byId.values()).sort(compareWorkspaceListSessions);
}

function buildTuiSessionListRows(
  workspace: Workspace,
  sessions: LocalSession[],
): TuiSessionListRow[] {
  return sessions.map((session) => ({
    id: session.path,
    source: "tui",
    status: "stopped",
    workspaceId: workspace.id,
    workspaceName: workspace.name,
    name: session.name,
    createdAt: session.createdAt,
    lastActivity: session.lastModified,
    lastModified: session.lastModified,
    model: session.model,
    messageCount: session.messageCount,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    firstMessage: session.firstMessage,
    piSessionId: session.piSessionId,
    path: session.path,
    cwd: session.cwd,
    pendingAskCount: 0,
  }));
}

function sessionListUrgencyScore(session: SessionListRow): number {
  if (session.pendingAskCount > 0) return 20;
  switch (session.status) {
    case "error":
      return 15;
    case "busy":
    case "starting":
    case "stopping":
      return 10;
    case "ready":
      return 5;
    case "stopped":
      return 0;
  }
}

function compareActiveSessionListRows(a: SessionListRow, b: SessionListRow): number {
  const urgency = sessionListUrgencyScore(b) - sessionListUrgencyScore(a);
  if (urgency !== 0) {
    return urgency;
  }
  if (b.lastActivity !== a.lastActivity) {
    return b.lastActivity - a.lastActivity;
  }
  return a.id.localeCompare(b.id);
}

function compareStoppedSessionListRows(a: SessionListRow, b: SessionListRow): number {
  if (b.lastActivity !== a.lastActivity) {
    return b.lastActivity - a.lastActivity;
  }
  return a.id.localeCompare(b.id);
}

function localBucketForTimestamp(
  timestampMs: number,
  nowMs: number,
): {
  bucketId: string;
  bucketKind: "day" | "month";
  startMs: number;
  endMs: number;
} {
  const date = new Date(timestampMs);
  const recentDayCutoffMs = nowMs - 30 * 86_400_000;
  if (timestampMs >= recentDayCutoffMs) {
    const start = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
    const y = date.getFullYear();
    const m = String(date.getMonth() + 1).padStart(2, "0");
    const d = String(date.getDate()).padStart(2, "0");
    return {
      bucketId: `day:${y}-${m}-${d}`,
      bucketKind: "day",
      startMs: start,
      endMs: start + 86_400_000,
    };
  }

  const start = new Date(date.getFullYear(), date.getMonth(), 1).getTime();
  const end = new Date(date.getFullYear(), date.getMonth() + 1, 1).getTime();
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  return {
    bucketId: `month:${y}-${m}`,
    bucketKind: "month",
    startMs: start,
    endMs: end,
  };
}

function mergeWorkspaceArchiveBuckets(
  managedBuckets: WorkspaceStoppedTimeBucketSnapshot[],
  olderImportableSessions: LocalSession[],
  nowMs: number,
): SessionListArchiveBucket[] {
  const merged = new Map<string, SessionListArchiveBucket>();

  for (const bucket of managedBuckets) {
    merged.set(bucket.bucketId, {
      bucketId: bucket.bucketId,
      bucketKind: bucket.bucketKind,
      startMs: bucket.startMs,
      endMs: bucket.endMs,
      itemCount: bucket.itemCount,
      managedStoppedCount: bucket.itemCount,
      importableLocalCount: 0,
      ...(bucket.latestActivity !== undefined ? { latestActivity: bucket.latestActivity } : {}),
    });
  }

  for (const session of olderImportableSessions) {
    const bucket = localBucketForTimestamp(session.lastModified, nowMs);
    const existing = merged.get(bucket.bucketId);
    if (existing) {
      existing.itemCount += 1;
      existing.importableLocalCount += 1;
      if (existing.latestActivity === undefined || session.lastModified > existing.latestActivity) {
        existing.latestActivity = session.lastModified;
      }
      continue;
    }

    merged.set(bucket.bucketId, {
      ...bucket,
      itemCount: 1,
      managedStoppedCount: 0,
      importableLocalCount: 1,
      latestActivity: session.lastModified,
    });
  }

  return Array.from(merged.values()).sort((lhs, rhs) => {
    const lhsLatest = lhs.latestActivity ?? lhs.startMs;
    const rhsLatest = rhs.latestActivity ?? rhs.startMs;
    if (lhsLatest !== rhsLatest) {
      return rhsLatest - lhsLatest;
    }
    return lhs.bucketId.localeCompare(rhs.bucketId);
  });
}

function splitImportableSessionsByRange(
  sessions: LocalSession[],
  sinceMs: number,
  untilMs: number,
): { visibleSessions: LocalSession[]; olderSessions: LocalSession[] } {
  const visibleSessions: LocalSession[] = [];
  const olderSessions: LocalSession[] = [];

  for (const session of sessions) {
    if (session.lastModified >= sinceMs && session.lastModified < untilMs) {
      visibleSessions.push(session);
    } else if (session.lastModified < sinceMs) {
      olderSessions.push(session);
    }
  }

  visibleSessions.sort((lhs, rhs) => rhs.lastModified - lhs.lastModified);
  olderSessions.sort((lhs, rhs) => rhs.lastModified - lhs.lastModified);
  return { visibleSessions, olderSessions };
}
