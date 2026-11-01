import {
  collectKnownLocalSessionIdentities,
  discoverLocalSessions,
  listCatalogedLocalSessions,
  isControlSessionLocalArtifact,
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
import { isControlRouteSession } from "./control-session.js";
import type { Storage } from "./storage.js";
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
  latestActivity: number;
};

export interface RecentWorkspaceSessionSummariesResult {
  sessions: ManagedSessionListRow[];
  serverNow: number;
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
    | "listWorkspaceTimeRangeSessionSnapshots"
    | "listWorkspaceStoppedActivityTimes"
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
    sinceMs?: number;
    untilMs?: number;
    nowMs?: number;
  }): RecentWorkspaceSessionSummariesResult {
    const serverNow = params.nowMs ?? Date.now();
    const hasExplicitTimeRange = params.sinceMs !== undefined || params.untilMs !== undefined;
    const workspaces = this.deps.storage.listWorkspaces();
    const workspaceSessions = workspaces.flatMap((workspace) =>
      (hasExplicitTimeRange
        ? this.deps.storage.listWorkspaceTimeRangeSessionSnapshots(
            workspace.id,
            params.sinceMs ?? Number.MIN_SAFE_INTEGER,
            exclusiveSessionRangeUntil(params.untilMs),
          )
        : params.recentDays > 0
          ? this.deps.storage.listRecentWorkspaceSessionSnapshots(
              workspace.id,
              params.recentDays,
              serverNow,
            )
          : this.deps.storage.listAllWorkspaceSessionSnapshots(workspace.id)
      ).filter(isOpenableManagedListSession),
    );
    const cutoffMs =
      !hasExplicitTimeRange && params.recentDays > 0
        ? serverNow - params.recentDays * 86_400_000
        : undefined;
    const controlSessions = this.deps.storage
      .listSessions()
      .filter(
        (session) =>
          isControlRouteSession(session) &&
          session.workspaceId === undefined &&
          isOpenableManagedListSession(session) &&
          (cutoffMs === undefined || session.lastActivity >= cutoffMs),
      );
    const projectedSessions = [...workspaceSessions, ...controlSessions];
    const mergedSessions = mergeActiveSessionsAcrossWorkspaces(
      this.deps.sessionRuntimes,
      projectedSessions,
      new Map(workspaces.map((workspace) => [workspace.id, workspace.name])),
      cutoffMs === undefined ? {} : { cutoffMs },
    ).filter((session) => sessionMatchesInclusiveTimeRange(session, params));

    const sessions = this.buildManagedSessionListRows(
      mergedSessions,
      collectPendingAttentionCounts(this.deps.sessionRuntimes),
    );

    return { sessions, serverNow };
  }

  async listWorkspaceSessionRows(params: {
    workspace: Workspace;
    statuses: ReadonlySet<SessionStatusFilter>;
    timeRange?: { sinceMs: number; untilMs: number };
    filterActiveByTimeRange?: boolean;
    worktreeId?: string;
    nowMs?: number;
  }): Promise<WorkspaceSessionCollectionResult> {
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
        params.workspace,
        attention,
        params.worktreeId,
        params.filterActiveByTimeRange ? params.timeRange : undefined,
      );
    }

    if (params.statuses.has("stopped") && params.timeRange) {
      response.stopped = await this.listWorkspaceStoppedSessionRows(
        params.workspace,
        params.timeRange,
        attention,
        serverNow,
        params.worktreeId,
      );
    }

    return response;
  }

  async listWorkspaceStoppedSessionBuckets(params: {
    workspace: Workspace;
    beforeMs: number;
    worktreeId?: string;
    nowMs?: number;
  }): Promise<WorkspaceStoppedSessionBucketsResult> {
    const serverNow = params.nowMs ?? Date.now();
    const importableSnapshot = await this.listWorkspaceImportableSessions(
      params.workspace,
      params.worktreeId,
    );
    this.refreshLocalSessionCatalogIfStale(importableSnapshot.lastScannedAt, serverNow);
    const olderImportableSessions = importableSnapshot.sessions
      .filter((session) => session.lastModified < params.beforeMs)
      .sort((lhs, rhs) => rhs.lastModified - lhs.lastModified);
    const buckets = buildOlderHistorySections(
      this.deps.storage.listWorkspaceStoppedActivityTimes(
        params.workspace.id,
        params.beforeMs,
        params.worktreeId,
      ),
      olderImportableSessions,
      params.beforeMs,
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
    workspace: Workspace,
    attention: PendingAttentionCounts,
    worktreeId?: string,
    timeRange?: { sinceMs: number; untilMs: number },
  ): ManagedSessionListRow[] {
    const sessions = mergeActiveWorkspaceSessions(
      this.deps.sessionRuntimes,
      this.deps.storage.listAllWorkspaceSessionSnapshots(workspace.id, worktreeId),
      workspace,
      { worktreeId },
    )
      .filter(isOpenableManagedListSession)
      .filter(isActiveListSession)
      .filter(
        (session) =>
          !timeRange ||
          (session.lastActivity >= timeRange.sinceMs && session.lastActivity < timeRange.untilMs),
      );
    return this.buildManagedSessionListRows(sessions, attention).sort(compareActiveSessionListRows);
  }

  private async listWorkspaceStoppedSessionRows(
    workspace: Workspace,
    timeRange: { sinceMs: number; untilMs: number },
    attention: PendingAttentionCounts,
    serverNow: number,
    worktreeId?: string,
  ): Promise<SessionListRow[]> {
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

    const importableSnapshot = await this.listWorkspaceImportableSessions(workspace, worktreeId);
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

  private async listWorkspaceImportableSessions(
    workspace: Workspace,
    worktreeId?: string,
  ): Promise<LocalSessionCatalogSnapshot> {
    const knownPiSessionIdentities = this.collectKnownPiSessionIdentities();
    const snapshot = listCatalogedLocalSessions(knownPiSessionIdentities, {
      dataDir: this.deps.storage.getDataDir(),
    });
    const hostMount = worktreeId
      ? (
          await resolveWorkspaceWorktree(workspace, worktreeId, {
            dataDir: this.deps.storage.getDataDir(),
          })
        )?.path
      : workspace.hostMount;
    // An unresolvable worktree has no folder to match; nothing imports from it.
    if (!hostMount) {
      return { ...snapshot, sessions: [] };
    }

    const dataDir = this.deps.storage.getDataDir();
    return {
      ...snapshot,
      sessions: snapshot.sessions.filter(
        (session) =>
          validateCwdAlignment(session.cwd, hostMount) &&
          !isControlSessionLocalArtifact(session.cwd, { dataDir }),
      ),
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
    const dataDir = this.deps.storage.getDataDir();
    // Defer off the request stack so workspace session list responses never pay
    // for cold Pi-home enumeration inline, even before discoverLocalSessions
    // hits its first await.
    setImmediate(() => {
      void discoverLocalSessions(knownPiSessionIdentities, { dataDir }).catch((error: unknown) => {
        log.warn("local_session_catalog.refresh_failed", {
          error: safeErrorMessage(error),
        });
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

function exclusiveSessionRangeUntil(inclusiveUntilMs: number | undefined): number {
  if (inclusiveUntilMs === undefined || inclusiveUntilMs >= Number.MAX_SAFE_INTEGER) {
    return Number.MAX_SAFE_INTEGER;
  }
  return inclusiveUntilMs + 1;
}

function sessionMatchesInclusiveTimeRange(
  session: Session,
  timeRange: { sinceMs?: number; untilMs?: number },
): boolean {
  if (timeRange.sinceMs !== undefined && session.lastActivity < timeRange.sinceMs) return false;
  if (timeRange.untilMs !== undefined && session.lastActivity > timeRange.untilMs) return false;
  return true;
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
  workspaceNames: ReadonlyMap<string, string>,
  filters: {
    cutoffMs?: number;
    untilMs?: number;
    worktreeId?: string;
  },
): Session[] {
  const byId = new Map(projectedSessions.map((session) => [session.id, session]));
  for (const activeSessionId of sessionRuntimes.getActiveSessionIds()) {
    const active = sessionRuntimes.getActiveSession(activeSessionId);
    if (!active || (!active.workspaceId && !isControlRouteSession(active))) {
      continue;
    }
    if (!sessionMatchesWorkspaceListFilters(active, filters)) {
      continue;
    }
    byId.set(active.id, withCurrentWorkspaceName(active, workspaceNames));
  }
  return Array.from(byId.values()).sort(compareWorkspaceListSessions);
}

/**
 * A live session keeps the workspace name from its last save, so a rename since then would
 * not show. Set the current one in place, as `Storage` does on read, so the row and the live
 * object agree.
 */
function withCurrentWorkspaceName(
  active: Session,
  workspaceNames: ReadonlyMap<string, string>,
): Session {
  const name = active.workspaceId ? workspaceNames.get(active.workspaceId) : undefined;
  if (name === undefined) delete active.workspaceName;
  else active.workspaceName = name;
  return active;
}

function mergeActiveWorkspaceSessions(
  sessionRuntimes: Pick<SessionRuntimes, "getActiveSession" | "getActiveSessionIds">,
  projectedSessions: Session[],
  workspace: Workspace,
  filters: {
    cutoffMs?: number;
    untilMs?: number;
    worktreeId?: string;
  },
): Session[] {
  const byId = new Map(projectedSessions.map((session) => [session.id, session]));
  const workspaceNames = new Map([[workspace.id, workspace.name]]);
  for (const activeSessionId of sessionRuntimes.getActiveSessionIds()) {
    const active = sessionRuntimes.getActiveSession(activeSessionId);
    if (!active || active.workspaceId !== workspace.id) {
      continue;
    }
    if (!sessionMatchesWorkspaceListFilters(active, filters)) {
      continue;
    }
    byId.set(active.id, withCurrentWorkspaceName(active, workspaceNames));
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

/** Older history uses day sections for this many calendar days, then month sections. */
const OLDER_HISTORY_DAY_SECTION_DAYS = 30;

/**
 * Where day sections give way to month sections: the local midnight that starts the day
 * 30 calendar days before `nowMs` (not 720 hours, which is a day off just after midnight
 * when daylight saving changes inside the window). Snapping to a midnight keeps every day
 * whole on one side of the line, so no session is in both a day section and a month section.
 */
function olderHistoryDayCutoffMs(nowMs: number): number {
  const now = new Date(nowMs);
  return new Date(
    now.getFullYear(),
    now.getMonth(),
    now.getDate() - OLDER_HISTORY_DAY_SECTION_DAYS,
  ).getTime();
}

/**
 * The older-history section an activity time belongs to, in the server's local time zone:
 * its calendar day when at or after `dayCutoffMs`, else its calendar month, which ends at
 * `dayCutoffMs` when the line falls inside it. Each day range runs to the next local
 * midnight, so a daylight-saving day spans 23 or 25 hours. This is the only owner of
 * section ids and ranges; Oppi and local Pi sessions both go through it, and the client
 * opens a section by asking for exactly `[startMs, endMs)`.
 */
function olderHistorySection(
  timestampMs: number,
  dayCutoffMs: number,
): Pick<SessionListArchiveBucket, "bucketId" | "bucketKind" | "startMs" | "endMs"> {
  const date = new Date(timestampMs);
  const y = date.getFullYear();
  const month = date.getMonth();
  const mm = String(month + 1).padStart(2, "0");
  if (timestampMs >= dayCutoffMs) {
    const day = date.getDate();
    return {
      bucketId: `day:${y}-${mm}-${String(day).padStart(2, "0")}`,
      bucketKind: "day",
      startMs: new Date(y, month, day).getTime(),
      endMs: new Date(y, month, day + 1).getTime(),
    };
  }
  return {
    bucketId: `month:${y}-${mm}`,
    bucketKind: "month",
    startMs: new Date(y, month, 1).getTime(),
    endMs: Math.min(new Date(y, month + 1, 1).getTime(), dayCutoffMs),
  };
}

/**
 * Older-history sections for sessions before `beforeMs`, the client's recent/older boundary.
 * A section never reaches past that boundary: when the client's midnight is not the
 * server's (another time zone, or an older client), the newest section ends at `beforeMs`
 * so opening it loads exactly what it counts and nothing from the recent list.
 */
function buildOlderHistorySections(
  managedStoppedActivityTimes: number[],
  olderImportableSessions: LocalSession[],
  beforeMs: number,
  nowMs: number,
): SessionListArchiveBucket[] {
  const dayCutoffMs = olderHistoryDayCutoffMs(nowMs);
  const sections = new Map<string, SessionListArchiveBucket>();

  function add(activityMs: number, source: "managed" | "importable"): void {
    const placement = olderHistorySection(activityMs, dayCutoffMs);
    let section = sections.get(placement.bucketId);
    if (!section) {
      section = {
        ...placement,
        endMs: Math.min(placement.endMs, beforeMs),
        itemCount: 0,
        managedStoppedCount: 0,
        importableLocalCount: 0,
        latestActivity: activityMs,
      };
      sections.set(placement.bucketId, section);
    }
    section.itemCount += 1;
    if (source === "managed") {
      section.managedStoppedCount += 1;
    } else {
      section.importableLocalCount += 1;
    }
    section.latestActivity = Math.max(section.latestActivity, activityMs);
  }

  for (const activityMs of managedStoppedActivityTimes) {
    add(activityMs, "managed");
  }
  for (const session of olderImportableSessions) {
    add(session.lastModified, "importable");
  }

  return Array.from(sections.values()).sort((lhs, rhs) => {
    if (lhs.latestActivity !== rhs.latestActivity) {
      return rhs.latestActivity - lhs.latestActivity;
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
