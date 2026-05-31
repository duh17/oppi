import type { IncomingMessage, ServerResponse } from "node:http";
import { existsSync, realpathSync } from "node:fs";
import { access, readFile, realpath, rm, stat, unlink } from "node:fs/promises";
import { resolve } from "node:path";
import { homedir } from "node:os";

import { isPathWithinRoot } from "../git-utils.js";
import {
  readSessionTrace,
  readSessionTraceByUuid,
  readSessionTraceFromFile,
  readSessionTraceFromFiles,
  findToolOutput,
  mergePermissionAuditEvents,
  type TraceViewMode,
} from "../trace.js";
import {
  collectFileMutations,
  reconstructBaselineFromCurrent,
  computeDiffLines,
  computeLineDiffStatsFromLines,
} from "../diff-core.js";
import { buildDiffHunks } from "../workspace-review-diff.js";
import {
  deleteCatalogedLocalSessionPaths,
  discoverLocalSessions,
  invalidateLocalSessionsCache,
  listCatalogedLocalSessions,
  validateLocalSessionPath,
  validateCwdAlignment,
  type LocalSessionCatalogSnapshot,
} from "../local-sessions.js";
import { buildPermissionMessage } from "../gate.js";
import {
  promoteStoppedMirrorToOppi,
  canResumeStoppedMirrorAsOppi,
} from "../mirror-session-resume.js";
import {
  type ChatAttachmentRef,
  type LocalSession,
  type Session,
  type SessionSummary,
  type Workspace,
} from "../types.js";
import { safeErrorMessage } from "../log-utils.js";
import { createLogger } from "../logger.js";
import { resolveSdkSessionCwd } from "../sdk-backend.js";
import { resolveInitialChatModel } from "../session-model-selection.js";
import { buildSessionSummary } from "../session-summary.js";
import {
  deleteSessionAttachments,
  getSessionAttachment,
  streamSessionAttachment,
} from "../session-attachments.js";
import { createSessionFileHandlers } from "./session-files.js";
import { decodeWorkspaceRoutePath } from "./workspace-files.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";
import type { WorkspaceStoppedTimeBucketSnapshot } from "../storage/session-dao.js";

const LOCAL_SESSION_META_READ_BYTES = 16_384;
const MAX_SESSION_FILE_BYTES = 10 * 1024 * 1024;
const LOCAL_SESSION_CATALOG_MAX_AGE_MS = 60_000;

const log = createLogger({ base: { component: "route_sessions" } });

function compareWorkspaceListSessions(a: Session, b: Session): number {
  if (b.lastActivity !== a.lastActivity) {
    return b.lastActivity - a.lastActivity;
  }
  return a.id.localeCompare(b.id);
}

function sessionMatchesWorkspaceListFilters(
  session: Session,
  filters: {
    cutoffMs?: number;
    untilMs?: number;
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

  return true;
}

export function createSessionRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  const sessionFileHandlers = createSessionFileHandlers(ctx, helpers);
  /** Full-text search across session content. */
  function handleSearchSessions(url: URL, res: ServerResponse): void {
    if (!ctx.searchIndex) {
      helpers.error(res, 503, "Search index not available");
      return;
    }

    const query = url.searchParams.get("q")?.trim();
    if (!query) {
      helpers.json(res, { results: [], query: "", totalResults: 0 });
      return;
    }

    const workspaceId = url.searchParams.get("workspaceId") ?? undefined;
    const limit = Math.min(parseInt(url.searchParams.get("limit") ?? "20", 10) || 20, 100);

    const results = ctx.searchIndex.search(query, workspaceId, limit);

    // Attach full session objects for display
    const enriched = results.map((r) => {
      const session = ctx.storage.getSession(r.sessionId);
      return {
        ...r,
        session: session ? ctx.ensureSessionContextWindow(session) : undefined,
      };
    });

    helpers.json(res, {
      results: enriched,
      query,
      totalResults: enriched.length,
    });
  }

  function mergeActiveWorkspaceSessions(
    projectedSessions: Session[],
    workspaceId: string,
    filters: {
      cutoffMs?: number;
      untilMs?: number;
    },
  ): Session[] {
    const byId = new Map(projectedSessions.map((session) => [session.id, session]));
    for (const activeSessionId of ctx.sessions.getActiveSessionIds()) {
      const active = ctx.sessions.getActiveSession(activeSessionId);
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

  function mergeActiveSessionsAcrossWorkspaces(
    projectedSessions: Session[],
    filters: {
      cutoffMs?: number;
      untilMs?: number;
    },
  ): Session[] {
    const byId = new Map(projectedSessions.map((session) => [session.id, session]));
    for (const activeSessionId of ctx.sessions.getActiveSessionIds()) {
      const active = ctx.sessions.getActiveSession(activeSessionId);
      if (!active?.workspaceId) {
        continue;
      }
      if (!sessionMatchesWorkspaceListFilters(active, filters)) {
        continue;
      }
      byId.set(active.id, active);
    }
    return Array.from(byId.values()).sort(compareWorkspaceListSessions);
  }

  function pendingAskSnapshots(workspaceId: string): Array<Record<string, unknown>> {
    const asks: Array<Record<string, unknown>> = [];
    for (const sessionId of ctx.sessions.getActiveSessionIds()) {
      const session = ctx.sessions.getActiveSession(sessionId);
      if (!session || session.workspaceId !== workspaceId) {
        continue;
      }

      const message = ctx.sessions.getPendingAskMessage(sessionId);
      if (
        !message ||
        message.type !== "extension_ui_request" ||
        message.method !== "ask" ||
        !message.questions
      ) {
        continue;
      }

      asks.push({
        id: message.id,
        sessionId: message.sessionId,
        workspaceId,
        questions: message.questions,
        allowCustom: message.allowCustom ?? true,
        ...(message.timeout !== undefined ? { timeout: message.timeout } : {}),
        ...(message.timeoutAt !== undefined ? { timeoutAt: message.timeoutAt } : {}),
      });
    }
    return asks;
  }

  function pendingPermissionSnapshots(
    workspaceId: string,
    nowMs: number,
  ): Array<Record<string, unknown>> {
    return ctx.gate
      .getPendingForUser()
      .filter((pending) => pending.workspaceId === workspaceId)
      .filter((pending) => pending.expires !== true || pending.timeoutAt > nowMs)
      .map((pending) => ({
        ...buildPermissionMessage(pending),
        workspaceId: pending.workspaceId,
      }));
  }

  function canonicalSessionFilePath(path: string): string {
    const resolved = resolve(path);
    if (!existsSync(resolved)) return resolved;
    try {
      return realpathSync(resolved);
    } catch {
      return resolved;
    }
  }

  function collectKnownPiSessionIdentities(): { files: Set<string>; piSessionIds: Set<string> } {
    const files = new Set<string>();
    const piSessionIds = new Set<string>();
    for (const session of ctx.storage.listSessions()) {
      if (session.piSessionId) {
        piSessionIds.add(session.piSessionId);
      }
      if (session.piSessionFile) {
        files.add(canonicalSessionFilePath(session.piSessionFile));
      }
      for (const file of session.piSessionFiles ?? []) {
        files.add(canonicalSessionFilePath(file));
      }
    }
    return { files, piSessionIds };
  }

  function sessionMatchesPiIdentity(
    session: Session,
    identity: { path: string; piSessionId?: string },
  ): boolean {
    if (identity.piSessionId && session.piSessionId === identity.piSessionId) {
      return true;
    }
    if (
      session.piSessionFile &&
      canonicalSessionFilePath(session.piSessionFile) === identity.path
    ) {
      return true;
    }
    return (session.piSessionFiles ?? []).some(
      (file) => canonicalSessionFilePath(file) === identity.path,
    );
  }

  function findSessionByPiIdentity(identity: {
    path: string;
    piSessionId?: string;
  }): Session | undefined {
    return ctx.storage
      .listSessions()
      .find((session) => sessionMatchesPiIdentity(session, identity));
  }

  function workspaceAttentionSnapshot(
    workspaceId: string,
    serverNow: number,
  ): {
    permissions: Array<Record<string, unknown>>;
    asks: Array<Record<string, unknown>>;
  } {
    return {
      permissions: pendingPermissionSnapshots(workspaceId, serverNow),
      asks: pendingAskSnapshots(workspaceId),
    };
  }

  function listWorkspaceImportableSessions(workspace: {
    hostMount?: string;
  }): LocalSessionCatalogSnapshot {
    const knownPiSessionIdentities = collectKnownPiSessionIdentities();
    const snapshot = listCatalogedLocalSessions(knownPiSessionIdentities, {
      dataDir: ctx.storage.getDataDir(),
    });
    if (!workspace.hostMount) {
      return snapshot;
    }

    return {
      ...snapshot,
      sessions: snapshot.sessions.filter((session) =>
        validateCwdAlignment(session.cwd, workspace.hostMount ?? ""),
      ),
    };
  }

  function refreshLocalSessionCatalogIfStale(lastScannedAt: number | undefined): void {
    if (
      lastScannedAt !== undefined &&
      Date.now() - lastScannedAt < LOCAL_SESSION_CATALOG_MAX_AGE_MS
    ) {
      return;
    }

    const knownPiSessionIdentities = collectKnownPiSessionIdentities();
    void discoverLocalSessions(knownPiSessionIdentities, {
      dataDir: ctx.storage.getDataDir(),
    }).catch((error: unknown) => {
      log.warn("local_session_catalog.refresh_failed", {
        error: safeErrorMessage(error),
      });
    });
  }

  type SessionListArchiveBucket = {
    bucketId: string;
    bucketKind: "day" | "month";
    startMs: number;
    endMs: number;
    itemCount: number;
    managedStoppedCount: number;
    importableLocalCount: number;
    latestActivity?: number;
  };

  type SessionStatusFilter = "active" | "stopped";

  type PendingAttentionCounts = {
    permissions: Map<string, number>;
    asks: Map<string, number>;
  };

  type ManagedSessionListRow = SessionSummary & {
    pendingPermissionCount: number;
    pendingAskCount: number;
  };

  type TuiSessionListRow = {
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
    pendingPermissionCount: 0;
    pendingAskCount: 0;
  };

  type SessionListRow = ManagedSessionListRow | TuiSessionListRow;

  function parseRequiredTimeRange(url: URL): { sinceMs: number; untilMs: number } | undefined {
    const sinceMs = Number.parseInt(url.searchParams.get("sinceMs") ?? "", 10);
    const untilMs = Number.parseInt(url.searchParams.get("untilMs") ?? "", 10);
    if (!Number.isFinite(sinceMs) || !Number.isFinite(untilMs) || sinceMs >= untilMs) {
      return undefined;
    }
    return { sinceMs, untilMs };
  }

  function parseOptionalTimeRange(url: URL): {
    timeRange?: { sinceMs: number; untilMs: number };
    error?: string;
  } {
    const hasSince = url.searchParams.has("sinceMs");
    const hasUntil = url.searchParams.has("untilMs");
    if (!hasSince && !hasUntil) {
      return {};
    }

    const timeRange = parseRequiredTimeRange(url);
    if (!timeRange || !hasSince || !hasUntil) {
      return { error: "sinceMs and untilMs must form a valid range when provided" };
    }

    return { timeRange };
  }

  function parseSessionStatusFilters(url: URL): {
    statuses?: Set<SessionStatusFilter>;
    error?: string;
  } {
    const raw = url.searchParams.get("status")?.trim();
    if (!raw) {
      return { error: "status is required" };
    }

    const statuses = new Set<SessionStatusFilter>();
    for (const part of raw.split(",")) {
      const status = part.trim();
      if (!status) {
        continue;
      }
      if (status !== "active" && status !== "stopped") {
        return { error: "status must include only 'active' and/or 'stopped'" };
      }
      statuses.add(status);
    }

    if (statuses.size === 0) {
      return { error: "status is required" };
    }

    return { statuses };
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
        if (
          existing.latestActivity === undefined ||
          session.lastModified > existing.latestActivity
        ) {
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

  function handleWorkspaceAttention(workspaceId: string, res: ServerResponse): void {
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const serverNow = Date.now();
    helpers.json(res, {
      workspaceId,
      serverNow,
      attention: workspaceAttentionSnapshot(workspaceId, serverNow),
    });
  }

  function isActiveListSession(session: Session): boolean {
    return session.status !== "stopped";
  }

  function incrementCount(map: Map<string, number>, key: string): void {
    map.set(key, (map.get(key) ?? 0) + 1);
  }

  function collectPendingAttentionCounts(serverNow: number): PendingAttentionCounts {
    const permissions = new Map<string, number>();
    for (const pending of ctx.gate.getPendingForUser()) {
      if (pending.expires === true && pending.timeoutAt <= serverNow) {
        continue;
      }
      incrementCount(permissions, pending.sessionId);
    }

    const asks = new Map<string, number>();
    for (const sessionId of ctx.sessions.getActiveSessionIds()) {
      const message = ctx.sessions.getPendingAskMessage(sessionId);
      if (
        message?.type === "extension_ui_request" &&
        message.method === "ask" &&
        message.questions
      ) {
        incrementCount(asks, sessionId);
      }
    }

    return { permissions, asks };
  }

  function buildManagedSessionListRows(
    sessions: Session[],
    attention: PendingAttentionCounts,
  ): ManagedSessionListRow[] {
    return sessions.map((session) => {
      const summary = buildSessionSummary(ctx.ensureSessionContextWindow(session));
      return {
        ...summary,
        pendingPermissionCount: attention.permissions.get(summary.id) ?? 0,
        pendingAskCount: attention.asks.get(summary.id) ?? 0,
      };
    });
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
      pendingPermissionCount: 0,
      pendingAskCount: 0,
    }));
  }

  function sessionListUrgencyScore(session: SessionListRow): number {
    if (session.pendingPermissionCount > 0) return 30;
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

  function listWorkspaceActiveSessionRows(
    workspaceId: string,
    attention: PendingAttentionCounts,
  ): ManagedSessionListRow[] {
    const sessions = mergeActiveWorkspaceSessions(
      ctx.storage.listAllWorkspaceSessionSnapshots(workspaceId),
      workspaceId,
      {},
    ).filter(isActiveListSession);
    return buildManagedSessionListRows(sessions, attention).sort(compareActiveSessionListRows);
  }

  function listWorkspaceStoppedSessionRows(
    workspace: Workspace,
    timeRange: { sinceMs: number; untilMs: number },
    attention: PendingAttentionCounts,
  ): SessionListRow[] {
    const managed = ctx.storage
      .listStoppedWorkspaceTimeRangeSessionSnapshots(
        workspace.id,
        timeRange.sinceMs,
        timeRange.untilMs,
      )
      .filter(
        (session) =>
          session.status === "stopped" &&
          session.lastActivity >= timeRange.sinceMs &&
          session.lastActivity < timeRange.untilMs,
      );
    const managedRows = buildManagedSessionListRows(managed, attention);

    const importableSnapshot = listWorkspaceImportableSessions(workspace);
    refreshLocalSessionCatalogIfStale(importableSnapshot.lastScannedAt);
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

  function handleListRecentWorkspaceSessionSummaries(
    req: IncomingMessage,
    res: ServerResponse,
  ): void {
    const url = new URL(req.url ?? "/", "http://localhost");
    const recentDaysParam = Number.parseInt(url.searchParams.get("recentDays") ?? "", 10);
    const recentDays =
      Number.isFinite(recentDaysParam) && recentDaysParam > 0 ? recentDaysParam : 0;
    const serverNow = Date.now();

    const projectedSessions = ctx.storage
      .listWorkspaces()
      .flatMap((workspace) =>
        recentDays > 0
          ? ctx.storage.listRecentWorkspaceSessionSnapshots(workspace.id, recentDays, serverNow)
          : ctx.storage.listAllWorkspaceSessionSnapshots(workspace.id),
      );
    const attention = collectPendingAttentionCounts(serverNow);
    const sessions = buildManagedSessionListRows(
      mergeActiveSessionsAcrossWorkspaces(
        projectedSessions,
        recentDays > 0 ? { cutoffMs: serverNow - recentDays * 86_400_000 } : {},
      ),
      attention,
    );

    helpers.compressedJson(req, res, { sessions });
  }

  function handleWorkspaceSessionBuckets(
    workspaceId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): void {
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const url = new URL(req.url ?? "/", "http://localhost");
    if (url.searchParams.get("status") !== "stopped") {
      helpers.error(res, 400, "status must be 'stopped'");
      return;
    }

    const beforeMs = Number.parseInt(url.searchParams.get("beforeMs") ?? "", 10);
    if (!Number.isFinite(beforeMs)) {
      helpers.error(res, 400, "beforeMs is required");
      return;
    }

    const serverNow = Date.now();
    const importableSnapshot = listWorkspaceImportableSessions(workspace);
    refreshLocalSessionCatalogIfStale(importableSnapshot.lastScannedAt);
    const olderImportableSessions = importableSnapshot.sessions
      .filter((session) => session.lastModified < beforeMs)
      .sort((lhs, rhs) => rhs.lastModified - lhs.lastModified);
    const buckets = mergeWorkspaceArchiveBuckets(
      ctx.storage.listWorkspaceStoppedTimeBuckets(workspaceId, beforeMs, serverNow),
      olderImportableSessions,
      serverNow,
    );

    helpers.compressedJson(req, res, {
      workspaceId,
      status: "stopped",
      beforeMs,
      serverNow,
      buckets,
    });
  }

  async function handleWorkspaceSessionCollection(
    workspaceId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const url = new URL(req.url ?? "/", "http://localhost");
    const parsedStatus = parseSessionStatusFilters(url);
    if (!parsedStatus.statuses) {
      helpers.error(res, 400, parsedStatus.error ?? "Invalid status filter");
      return;
    }

    const parsedTimeRange = parseOptionalTimeRange(url);
    if (parsedTimeRange.error) {
      helpers.error(res, 400, parsedTimeRange.error);
      return;
    }

    if (parsedStatus.statuses.has("stopped") && !parsedTimeRange.timeRange) {
      helpers.error(res, 400, "sinceMs and untilMs are required when status includes stopped");
      return;
    }

    const serverNow = Date.now();
    const attention = collectPendingAttentionCounts(serverNow);
    const response: {
      workspaceId: string;
      sinceMs?: number;
      untilMs?: number;
      serverNow: number;
      active?: SessionListRow[];
      stopped?: SessionListRow[];
    } = {
      workspaceId,
      serverNow,
    };

    if (parsedTimeRange.timeRange) {
      response.sinceMs = parsedTimeRange.timeRange.sinceMs;
      response.untilMs = parsedTimeRange.timeRange.untilMs;
    }

    if (parsedStatus.statuses.has("active")) {
      response.active = listWorkspaceActiveSessionRows(workspaceId, attention);
    }

    if (parsedStatus.statuses.has("stopped") && parsedTimeRange.timeRange) {
      response.stopped = listWorkspaceStoppedSessionRows(
        workspace,
        parsedTimeRange.timeRange,
        attention,
      );
    }

    helpers.compressedJson(req, res, response);
  }

  function requireWorkspaceSession(
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): Session | null {
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return null;
    }

    const session = ctx.storage.getSession(sessionId);
    if (!session) {
      helpers.error(res, 404, "Session not found");
      return null;
    }

    if (session.workspaceId !== workspaceId) {
      helpers.error(res, 400, "Session does not belong to this workspace");
      return null;
    }

    return session;
  }

  async function handleCreateWorkspaceSession(
    workspaceId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const body = await helpers.parseBody<{
      name?: string;
      model?: string;
      piSessionFile?: string;
      prompt?: string;
      thinking?: string;
      parentSessionId?: string;
      ephemeral?: boolean;
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      attachments?: ChatAttachmentRef[];
    }>(req);
    const requestedModel = body.model;

    // ── Local session import: validate path confinement + CWD alignment ──
    if (body.piSessionFile) {
      const validation = validateLocalSessionPath(body.piSessionFile);
      if ("error" in validation) {
        helpers.error(res, 400, `Invalid session file: ${validation.error}`);
        return;
      }

      // Read identity and CWD from the JSONL header for alignment/coalescing.
      const localHeader = await readLocalSessionHeader(validation.path);
      if (!localHeader?.cwd) {
        helpers.error(res, 400, "Cannot read session CWD from file");
        return;
      }

      if (!workspace.hostMount) {
        helpers.error(res, 400, "Workspace has no hostMount configured");
        return;
      }

      if (!validateCwdAlignment(localHeader.cwd, workspace.hostMount)) {
        helpers.error(
          res,
          400,
          `Session CWD (${localHeader.cwd}) is not within workspace path (${workspace.hostMount})`,
        );
        return;
      }

      // Extract name and first message from the local session JSONL.
      const localMeta = await readLocalSessionMeta(validation.path);
      const existingSession = findSessionByPiIdentity({
        path: validation.path,
        piSessionId: localHeader.piSessionId,
      });
      if (existingSession) {
        existingSession.workspaceId = workspace.id;
        existingSession.workspaceName = workspace.name;
        existingSession.piSessionFile = validation.path;
        existingSession.piSessionFiles = Array.from(
          new Set([...(existingSession.piSessionFiles ?? []), validation.path]),
        );
        if (localHeader.piSessionId) existingSession.piSessionId = localHeader.piSessionId;
        if (!existingSession.firstMessage && localMeta?.firstMessage) {
          existingSession.firstMessage = localMeta.firstMessage.slice(0, 200);
        }
        if (!existingSession.name && body.name) {
          existingSession.name = body.name;
        }
        ctx.storage.saveSession(existingSession);
        invalidateLocalSessionsCache();
        helpers.json(res, { session: ctx.ensureSessionContextWindow(existingSession) });
        return;
      }

      let sessionName = body.name;
      if (!sessionName) {
        sessionName = localMeta?.name || localMeta?.firstMessage?.slice(0, 80);
      }

      const modelSelection = resolveInitialChatModel({
        requestModel: requestedModel,
        // Imports should preserve the source trace model when the client does not
        // explicitly override it. Leaving the model undefined lets Pi restore it
        // from the imported JSONL/session state.
        includeWorkspaceDefault: false,
      });
      const session = ctx.storage.createSession(sessionName, modelSelection.model);

      session.workspaceId = workspace.id;
      session.workspaceName = workspace.name;
      if (localMeta?.firstMessage) {
        session.firstMessage = localMeta.firstMessage.slice(0, 200);
      }
      session.piSessionFile = validation.path;
      session.piSessionFiles = [validation.path];
      if (localHeader.piSessionId) session.piSessionId = localHeader.piSessionId;
      ctx.storage.saveSession(session);
      invalidateLocalSessionsCache();

      const hydrated = ctx.ensureSessionContextWindow(session);
      helpers.json(res, { session: hydrated }, 201);
      return;
    }

    // ── Standard new session ──
    const parentSessionId = body.parentSessionId?.trim();
    let parentSession: Session | undefined;
    if (parentSessionId) {
      parentSession = ctx.storage.getSession(parentSessionId);
      if (!parentSession) {
        helpers.error(res, 404, "Parent session not found");
        return;
      }
      if (parentSession.workspaceId !== workspace.id) {
        helpers.error(res, 400, "Parent session does not belong to this workspace");
        return;
      }
    }

    const modelSelection = resolveInitialChatModel({
      requestModel: requestedModel,
      sourceSessionModel: parentSession?.model,
      workspace,
    });
    const session = ctx.storage.createSession(body.name, modelSelection.model);

    session.workspaceId = workspace.id;
    session.workspaceName = workspace.name;
    if (parentSessionId) {
      session.parentSessionId = parentSessionId;
    }
    if (body.ephemeral === true) {
      session.ephemeral = true;
    }
    if (body.thinking) {
      session.thinkingLevel = body.thinking;
    }
    ctx.storage.saveSession(session);

    // ── Optional prompt: auto-resume + send first message ──
    const prompt = body.prompt?.trim();
    if (prompt) {
      try {
        await ctx.sessions.startSession(session.id, workspace);
        if (body.thinking) {
          await ctx.sessions.forwardClientCommand(session.id, {
            type: "set_thinking_level",
            level: body.thinking,
          });
          // Keep our local reference in sync — forwardClientCommand persists
          // on the active session object (a different reference read from disk
          // during startSession), so without this the final saveSession below
          // would overwrite the thinking level with undefined.
          session.thinkingLevel = body.thinking;
        }
        await ctx.sessions.sendPrompt(session.id, prompt, {
          ...(body.images ? { images: body.images } : {}),
          ...(body.attachments ? { attachments: body.attachments } : {}),
        });
        session.firstMessage = prompt.slice(0, 200);
        ctx.storage.saveSession(session);
      } catch (_err: unknown) {
        // Session was created but prompt delivery failed — return it
        // with prompted: false so the client knows to retry or send manually.
        const started = ctx.ensureSessionContextWindow(session);
        helpers.json(res, { session: started, prompted: false }, 201);
        return;
      }

      const started = ctx.ensureSessionContextWindow(session);
      helpers.json(res, { session: started, prompted: true }, 201);
      return;
    }

    const hydrated = ctx.ensureSessionContextWindow(session);
    helpers.json(res, { session: hydrated }, 201);
  }

  /** Read identity fields from a pi session JSONL header (first line). */
  async function readLocalSessionHeader(
    filePath: string,
  ): Promise<{ cwd: string; piSessionId?: string } | null> {
    try {
      const content = await readFile(filePath, "utf8");
      const firstLine = content.split("\n")[0];
      if (!firstLine) return null;
      const header = JSON.parse(firstLine) as Record<string, unknown>;
      const cwd = typeof header.cwd === "string" ? header.cwd : "";
      if (!cwd) return null;
      return {
        cwd,
        ...(typeof header.id === "string" ? { piSessionId: header.id } : {}),
      };
    } catch {
      return null;
    }
  }

  /** Read name and first message from a local JSONL session (first 16KB only). */
  async function readLocalSessionMeta(
    filePath: string,
  ): Promise<{ name?: string; firstMessage?: string } | null> {
    try {
      const content = (await readFile(filePath, "utf8")).slice(0, LOCAL_SESSION_META_READ_BYTES);
      const lines = content.split("\n");
      let name: string | undefined;
      let firstMessage: string | undefined;

      for (const line of lines) {
        if (!line.trim()) continue;
        let entry: Record<string, unknown>;
        try {
          entry = JSON.parse(line) as Record<string, unknown>;
        } catch {
          continue;
        }
        if (entry.type === "session_info") {
          const n = entry.name;
          if (typeof n === "string" && n.trim()) name = n.trim();
        }
        if (!firstMessage && entry.type === "message") {
          const msg = entry.message as Record<string, unknown> | undefined;
          if (msg?.role === "user") {
            const c = msg.content;
            if (typeof c === "string") firstMessage = c;
            else if (Array.isArray(c)) {
              const t = c.find(
                (x: unknown) =>
                  typeof x === "object" &&
                  x !== null &&
                  (x as Record<string, unknown>).type === "text",
              ) as { text?: string } | undefined;
              if (t?.text) firstMessage = t.text;
            }
          }
        }
        if (name && firstMessage) break;
      }
      return { name, firstMessage };
    } catch {
      return null;
    }
  }

  async function handleResumeWorkspaceSession(
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const session = ctx.storage.getSession(sessionId);
    if (!session) {
      helpers.error(res, 404, "Session not found");
      return;
    }

    if (session.workspaceId !== workspaceId) {
      helpers.error(res, 400, "Session does not belong to this workspace");
      return;
    }

    if (session.ephemeral) {
      helpers.error(res, 400, "Incognito sessions cannot be resumed");
      return;
    }

    if (session.runtime === "pi-tui") {
      const mirrorConnected = ctx.mirrorRuntime?.isSessionConnected?.(sessionId) === true;
      if (!canResumeStoppedMirrorAsOppi(session, mirrorConnected)) {
        const active = ctx.mirrorRuntime?.getActiveSession(sessionId) ?? session;
        helpers.json(res, { session: ctx.ensureSessionContextWindow(active) });
        return;
      }

      promoteStoppedMirrorToOppi(session);
      ctx.storage.saveSession(session);
    }

    if (ctx.sessions.isActive(sessionId)) {
      const active = ctx.sessions.getActiveSession(sessionId);
      const hydrated = active ? ctx.ensureSessionContextWindow(active) : session;
      helpers.json(res, { session: hydrated });
      return;
    }

    try {
      const started = await ctx.sessions.startSession(sessionId, workspace);
      const hydrated = ctx.ensureSessionContextWindow(started);
      helpers.json(res, { session: hydrated });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Resume failed";
      log.error("sessions.resume.failed", {
        sessionId,
        workspaceId,
        error: safeErrorMessage(err),
      });
      helpers.error(res, 500, message);
    }
  }

  async function handleForkWorkspaceSession(
    workspaceId: string,
    sourceSessionId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const sourceSession = ctx.storage.getSession(sourceSessionId);
    if (!sourceSession) {
      helpers.error(res, 404, "Session not found");
      return;
    }

    if (sourceSession.workspaceId !== workspaceId) {
      helpers.error(res, 400, "Session does not belong to this workspace");
      return;
    }

    const body = await helpers.parseBody<{ entryId?: string; name?: string }>(req);
    const entryId = body.entryId?.trim() || "";
    if (!entryId) {
      helpers.error(res, 400, "entryId required");
      return;
    }

    await ctx.sessions.refreshSessionState(sourceSessionId);

    const latestSource = ctx.storage.getSession(sourceSessionId) || sourceSession;
    const sourceSessionFile =
      latestSource.piSessionFile ||
      latestSource.piSessionFiles?.[latestSource.piSessionFiles.length - 1];

    if (!sourceSessionFile) {
      helpers.error(res, 409, "Source session has no trace file to fork from");
      return;
    }

    const sourceName = latestSource.name?.trim() || `Session ${latestSource.id.slice(0, 8)}`;
    const requestedName = body.name?.trim();
    const forkName = (
      requestedName && requestedName.length > 0 ? requestedName : `Fork: ${sourceName}`
    ).slice(0, 160);

    const forkModelSelection = resolveInitialChatModel({
      sourceSessionModel: latestSource.model,
      workspace,
    });
    const forkSession = ctx.storage.createSession(forkName, forkModelSelection.model);

    // Pi records file-level ancestry for forks in the JSONL header (`parentSession`).
    // Do not map that to Oppi `parentSessionId`: in Oppi, parent/child session
    // trees are reserved for spawned subagents. Timeline forks are independent
    // root sessions in the workspace list.
    forkSession.workspaceId = workspace.id;
    forkSession.workspaceName = workspace.name;
    forkSession.piSessionFile = sourceSessionFile;
    forkSession.piSessionFiles = Array.from(
      new Set([...(latestSource.piSessionFiles || []), sourceSessionFile]),
    );

    if (latestSource.thinkingLevel) forkSession.thinkingLevel = latestSource.thinkingLevel;
    if (latestSource.contextWindow) forkSession.contextWindow = latestSource.contextWindow;

    ctx.storage.saveSession(forkSession);

    try {
      await ctx.sessions.startSession(forkSession.id, workspace);
      await ctx.sessions.runCommand(forkSession.id, { type: "fork", entryId });
      await ctx.sessions.refreshSessionState(forkSession.id);
    } catch (err: unknown) {
      await ctx.sessions.stopSession(forkSession.id).catch(() => {});
      ctx.storage.deleteSession(forkSession.id);
      const message = err instanceof Error ? err.message : "Fork failed";
      log.error("sessions.fork.failed", {
        workspaceId,
        sourceSessionId,
        forkSessionId: forkSession.id,
        entryId,
        error: safeErrorMessage(err),
      });
      helpers.error(res, 500, message);
      return;
    }

    const created = ctx.storage.getSession(forkSession.id) || forkSession;
    helpers.json(res, { session: ctx.ensureSessionContextWindow(created) }, 201);
  }

  async function handleStopSession(
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const session = requireWorkspaceSession(workspaceId, sessionId, res);
    if (!session) return;

    const hydratedSession = ctx.ensureSessionContextWindow(session);

    try {
      if (session.runtime === "pi-tui") {
        if (!ctx.mirrorRuntime) {
          helpers.error(res, 503, "pi-tui runtime is not available");
          return;
        }
        await ctx.mirrorRuntime.stopSession(sessionId);
      } else if (ctx.sessions.isActive(sessionId)) {
        await ctx.sessions.stopSession(sessionId);
      } else {
        hydratedSession.status = "stopped";
        hydratedSession.currentTurnStartedAt = undefined;
        hydratedSession.lastActivity = Date.now();
        ctx.storage.saveSession(hydratedSession);
      }
    } catch (error: unknown) {
      const message = safeErrorMessage(error);
      helpers.error(
        res,
        session.runtime === "pi-tui" && message.includes("not connected") ? 409 : 500,
        message,
      );
      return;
    }

    const updatedSession = ctx.storage.getSession(sessionId);
    const hydratedUpdated = updatedSession
      ? ctx.ensureSessionContextWindow(updatedSession)
      : updatedSession;
    helpers.json(res, { ok: true, session: hydratedUpdated });
  }

  // ─── Tool Output by ID ───

  async function handleGetFullToolOutput(
    workspaceId: string,
    sessionId: string,
    toolCallId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    if (!requireWorkspaceSession(workspaceId, sessionId, res)) return;

    const fullOutputPath = ctx.sessions.getToolFullOutputPath(sessionId, toolCallId);
    if (!fullOutputPath) {
      helpers.error(res, 404, "Full tool output not found");
      return;
    }

    try {
      const output = await readFile(fullOutputPath, "utf8");
      helpers.compressedJson(req, res, { toolCallId, output });
    } catch {
      helpers.error(res, 404, "Full tool output not found");
    }
  }

  async function handleGetSessionAttachment(
    workspaceId: string,
    sessionId: string,
    attachmentId: string,
    res: ServerResponse,
  ): Promise<void> {
    const session = ctx.storage.getSession(sessionId);
    if (!session) {
      helpers.error(res, 404, "Session not found");
      return;
    }
    if (session.workspaceId !== workspaceId) {
      helpers.error(res, 400, "Session does not belong to this workspace");
      return;
    }

    const attachment = await getSessionAttachment(
      ctx.storage.getDataDir(),
      sessionId,
      attachmentId,
    );
    if (!attachment) {
      helpers.error(res, 404, "Attachment not found");
      return;
    }

    streamSessionAttachment(attachment, res);
  }

  async function handleGetToolOutput(
    workspaceId: string,
    sessionId: string,
    toolCallId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const session = requireWorkspaceSession(workspaceId, sessionId, res);
    if (!session) return;

    const jsonlPaths = await collectExistingSessionJsonlPaths(session);

    for (const jsonlPath of jsonlPaths) {
      const output = findToolOutput(jsonlPath, toolCallId);
      if (output !== null) {
        helpers.compressedJson(req, res, {
          toolCallId,
          output: output.text,
          isError: output.isError,
        });
        return;
      }
    }

    helpers.error(res, 404, "Tool output not found");
  }

  async function collectExistingSessionJsonlPaths(session: Session): Promise<string[]> {
    const candidates = [...(session.piSessionFiles ?? [])];
    if (session.piSessionFile) {
      candidates.push(session.piSessionFile);
    }

    const uniquePaths = Array.from(new Set(candidates));
    const existing = await Promise.all(
      uniquePaths.map(async (candidate) => ({
        candidate,
        exists: await pathExists(candidate),
      })),
    );

    return existing.filter((entry) => entry.exists).map((entry) => entry.candidate);
  }

  async function deleteReferencedLocalPiSessionJsonlFiles(session: Session): Promise<string[]> {
    const existingPaths = await collectExistingSessionJsonlPaths(session);
    const deleteTargets = new Set<string>();

    for (const candidate of existingPaths) {
      const validation = validateLocalSessionPath(candidate);
      if ("error" in validation) {
        // Only local pi session files can reappear in local-session discovery.
        // Never unlink arbitrary paths from session metadata.
        log.debug("sessions.delete.skip_non_local_pi_trace", {
          sessionId: session.id,
          path: candidate,
          reason: validation.error,
        });
        continue;
      }
      deleteTargets.add(validation.path);
    }

    const deletedPaths = Array.from(deleteTargets);
    if (deletedPaths.length > 0) {
      deleteCatalogedLocalSessionPaths(deletedPaths, { dataDir: ctx.storage.getDataDir() });
    }

    for (const target of deletedPaths) {
      await unlink(target);
    }

    if (deletedPaths.length > 0) {
      invalidateLocalSessionsCache();
    }

    return deletedPaths;
  }

  async function handleGetSessionOverallDiff(
    workspaceId: string,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const session = requireWorkspaceSession(workspaceId, sessionId, res);
    if (!session) return;

    const reqPath = url.searchParams.get("path")?.trim();
    if (!reqPath) {
      helpers.error(res, 400, "path parameter required");
      return;
    }

    const trace = loadSessionTrace(session);
    if (!trace || trace.length === 0) {
      helpers.error(res, 404, "Session trace not found");
      return;
    }

    const mutations = collectFileMutations(trace, reqPath);

    if (mutations.length === 0) {
      helpers.error(res, 404, "No file mutations found for path");
      return;
    }

    const currentText = await readCurrentFileText(session, reqPath);
    const baselineText = reconstructBaselineFromCurrent(currentText, mutations);
    const flatLines = computeDiffLines(baselineText, currentText);
    const hunks = buildDiffHunks(flatLines);
    const stats = computeLineDiffStatsFromLines(flatLines);

    helpers.json(res, {
      workspaceId: session.workspaceId ?? "",
      path: reqPath,
      baselineText,
      currentText,
      addedLines: stats.added,
      removedLines: stats.removed,
      hunks,
      revisionCount: mutations.length,
      cacheKey: `${sessionId}:${reqPath}:${mutations[mutations.length - 1]?.id ?? "none"}`,
    });
  }

  async function readCurrentFileText(session: Session, reqPath: string): Promise<string> {
    const workRoot = await resolveWorkRoot(session);
    if (!workRoot) return "";

    const target = resolve(workRoot, reqPath);
    try {
      const resolved = await realpath(target);
      const realWorkRoot = await realpath(workRoot);
      if (!isPathWithinRoot(resolved, realWorkRoot)) {
        return "";
      }
      const fileStat = await stat(resolved);
      if (!fileStat.isFile() || fileStat.size > MAX_SESSION_FILE_BYTES) return "";
      return await readFile(resolved, "utf8");
    } catch {
      return "";
    }
  }

  function traceBaseDir(): string {
    const storageWithDataDir = ctx.storage as {
      getDataDir?: () => string;
    };
    return storageWithDataDir.getDataDir?.() ?? process.cwd();
  }

  function loadSessionTrace(
    session: Session,
    traceView: TraceViewMode = "context",
    leafId?: string | null,
  ): ReturnType<typeof readSessionTrace> {
    const baseDir = traceBaseDir();
    const traceOptions = {
      view: traceView,
      attachmentDataDir: baseDir,
      attachmentSessionId: session.id,
      ...(leafId !== undefined ? { leafId } : {}),
    };
    let trace = readSessionTrace(baseDir, session.id, session.workspaceId, traceOptions);

    if ((!trace || trace.length === 0) && session.piSessionFiles?.length) {
      trace = readSessionTraceFromFiles(session.piSessionFiles, traceOptions);
    }
    if ((!trace || trace.length === 0) && session.piSessionFile) {
      trace = readSessionTraceFromFile(session.piSessionFile, traceOptions);
    }
    if ((!trace || trace.length === 0) && session.piSessionId) {
      trace = readSessionTraceByUuid(
        baseDir,
        session.piSessionId,
        session.workspaceId,
        traceOptions,
      );
    }

    return trace;
  }

  async function resolveWorkRoot(session: Session): Promise<string | null> {
    const workspace = session.workspaceId
      ? ctx.storage.getWorkspace(session.workspaceId)
      : undefined;

    if (workspace?.hostMount) {
      const resolved = resolveSdkSessionCwd(workspace);
      return (await pathExists(resolved)) ? resolved : null;
    }
    return homedir();
  }

  async function deleteWorkspaceSessionAttachmentCopies(session: Session): Promise<boolean> {
    const workspace = session.workspaceId
      ? ctx.storage.getWorkspace(session.workspaceId)
      : undefined;
    if (!workspace?.hostMount) return false;

    const workRoot = resolveSdkSessionCwd(workspace);
    if (!(await pathExists(workRoot))) return false;

    const workRootReal = await realpath(workRoot);
    const attachmentsRoot = resolve(workRootReal, ".pi", "attachments");
    const sessionAttachmentsDir = resolve(attachmentsRoot, session.id);
    if (!isPathWithinRoot(sessionAttachmentsDir, attachmentsRoot)) {
      throw new Error("Refusing to delete session attachments outside workspace attachment root");
    }

    const existed = await pathExists(sessionAttachmentsDir);
    await rm(sessionAttachmentsDir, { recursive: true, force: true });
    return existed;
  }

  function handleGetSessionEvents(
    workspaceId: string,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): void {
    if (!requireWorkspaceSession(workspaceId, sessionId, res)) return;

    const sinceParam = url.searchParams.get("since");
    const sinceSeq = sinceParam ? Number.parseInt(sinceParam, 10) : 0;
    if (!Number.isFinite(sinceSeq) || sinceSeq < 0) {
      helpers.error(res, 400, "since must be a non-negative integer");
      return;
    }

    const catchUp = ctx.sessions.getCatchUp(sessionId, sinceSeq);
    if (!catchUp) {
      helpers.error(res, 404, "Session not active");
      return;
    }

    helpers.json(res, {
      events: catchUp.events,
      currentSeq: catchUp.currentSeq,
      session: ctx.ensureSessionContextWindow(catchUp.session),
      catchUpComplete: catchUp.catchUpComplete,
    });
  }

  function resolveTraceView(url: URL): TraceViewMode {
    const view = url.searchParams.get("view");
    return view === "full" ? "full" : "context";
  }

  async function handleGetSession(
    req: IncomingMessage,
    workspaceId: string,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const session = requireWorkspaceSession(workspaceId, sessionId, res);
    if (!session) return;

    const traceView = resolveTraceView(url);
    const live = await ctx.sessions.refreshSessionState(sessionId);
    const refreshedSession = ctx.storage.getSession(sessionId) || session;
    const hydratedSession = ctx.ensureSessionContextWindow(refreshedSession);
    const baseDir = traceBaseDir();

    let trace = loadSessionTrace(hydratedSession, traceView, live?.leafId);

    if (!trace || trace.length === 0) {
      const traceOptions = {
        view: traceView,
        attachmentDataDir: traceBaseDir(),
        attachmentSessionId: sessionId,
        ...(live?.leafId !== undefined ? { leafId: live.leafId } : {}),
      };

      if (live?.sessionFile) {
        trace = readSessionTraceFromFile(live.sessionFile, traceOptions);
      }
      if ((!trace || trace.length === 0) && live?.sessionId) {
        trace = readSessionTraceByUuid(
          baseDir,
          live.sessionId,
          hydratedSession.workspaceId,
          traceOptions,
        );
      }

      const refreshed = ctx.storage.getSession(sessionId);
      if (refreshed && (!trace || trace.length === 0)) {
        ctx.ensureSessionContextWindow(refreshed);
        trace = loadSessionTrace(refreshed, traceView, live?.leafId);
      }
    }

    const latestSession = ctx.storage.getSession(sessionId) || hydratedSession;
    const hydratedLatest = ctx.ensureSessionContextWindow(latestSession);
    const auditEntries = ctx.gate.auditLog.query({
      sessionId,
      workspaceId,
      limit: 500,
    });
    const timelineTrace = mergePermissionAuditEvents(trace || [], auditEntries);
    helpers.compressedJson(req, res, { session: hydratedLatest, trace: timelineTrace });
  }

  async function handleDeleteSession(
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const session = requireWorkspaceSession(workspaceId, sessionId, res);
    if (!session) return;

    await ctx.sessions.stopSession(sessionId);

    let deletedTracePaths: string[] = [];
    let deletedWorkspaceAttachmentCopies = false;
    try {
      deletedTracePaths = await deleteReferencedLocalPiSessionJsonlFiles(session);
      if (deletedTracePaths.length > 0) {
        log.info("sessions.delete.local_pi_traces_deleted", {
          sessionId,
          deletedTraceCount: deletedTracePaths.length,
        });
      }
      deletedWorkspaceAttachmentCopies = await deleteWorkspaceSessionAttachmentCopies(session);
    } catch (err: unknown) {
      log.error("sessions.delete.files_delete_failed", {
        sessionId,
        error: safeErrorMessage(err),
      });
      helpers.error(res, 500, "Failed to delete session files");
      return;
    }

    ctx.storage.deleteSession(sessionId);
    ctx.searchIndex?.deleteSession(sessionId);
    const deletedGeneratedMediaAttachments = deleteSessionAttachments(
      ctx.storage.getDataDir(),
      sessionId,
    );

    helpers.json(res, {
      ok: true,
      deleted: {
        sqliteMetadata: true,
        localPiJsonlFiles: deletedTracePaths.length,
        workspaceAttachmentCopies: deletedWorkspaceAttachmentCopies,
        generatedMediaAttachments: deletedGeneratedMediaAttachments,
      },
    });
  }

  return async ({ method, path, url, req, res }) => {
    // ── Session search ──
    if (path === "/sessions/search" && method === "GET") {
      handleSearchSessions(url, res);
      return true;
    }

    if (path === "/sessions/recent" && method === "GET") {
      handleListRecentWorkspaceSessionSummaries(req, res);
      return true;
    }

    // ── Workspace-scoped session routes (v2 API) ──

    const wsAttentionMatch = path.match(/^\/workspaces\/([^/]+)\/attention$/);
    if (wsAttentionMatch && method === "GET") {
      handleWorkspaceAttention(wsAttentionMatch[1], res);
      return true;
    }

    const wsSessionBucketsMatch = path.match(/^\/workspaces\/([^/]+)\/session-buckets$/);
    if (wsSessionBucketsMatch && method === "GET") {
      handleWorkspaceSessionBuckets(wsSessionBucketsMatch[1], req, res);
      return true;
    }

    const wsSessionsMatch = path.match(/^\/workspaces\/([^/]+)\/sessions$/);
    if (wsSessionsMatch && method === "GET") {
      await handleWorkspaceSessionCollection(wsSessionsMatch[1], req, res);
      return true;
    }
    if (wsSessionsMatch && method === "POST") {
      await handleCreateWorkspaceSession(wsSessionsMatch[1], req, res);
      return true;
    }

    const wsSessionStopMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stop$/);
    if (wsSessionStopMatch && method === "POST") {
      await handleStopSession(wsSessionStopMatch[1], wsSessionStopMatch[2], res);
      return true;
    }

    const wsSessionResumeMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/resume$/);
    if (wsSessionResumeMatch && method === "POST") {
      await handleResumeWorkspaceSession(wsSessionResumeMatch[1], wsSessionResumeMatch[2], res);
      return true;
    }

    const wsSessionForkMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/fork$/);
    if (wsSessionForkMatch && method === "POST") {
      await handleForkWorkspaceSession(wsSessionForkMatch[1], wsSessionForkMatch[2], req, res);
      return true;
    }

    const wsSessionAttachmentMatch = path.match(
      /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/attachments\/([^/]+)$/,
    );
    if (wsSessionAttachmentMatch && method === "GET") {
      await handleGetSessionAttachment(
        wsSessionAttachmentMatch[1],
        wsSessionAttachmentMatch[2],
        wsSessionAttachmentMatch[3],
        res,
      );
      return true;
    }

    const wsSessionToolOutputMatch = path.match(
      /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/tool-output\/([^/]+)$/,
    );
    if (wsSessionToolOutputMatch && method === "GET") {
      if (url.searchParams.get("full") === "true") {
        await handleGetFullToolOutput(
          wsSessionToolOutputMatch[1],
          wsSessionToolOutputMatch[2],
          wsSessionToolOutputMatch[3],
          req,
          res,
        );
      } else {
        await handleGetToolOutput(
          wsSessionToolOutputMatch[1],
          wsSessionToolOutputMatch[2],
          wsSessionToolOutputMatch[3],
          req,
          res,
        );
      }
      return true;
    }

    const wsSessionChangesMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/changes$/);
    if (wsSessionChangesMatch && method === "GET") {
      await sessionFileHandlers.handleListSessionChanges(
        wsSessionChangesMatch[1],
        wsSessionChangesMatch[2],
        res,
      );
      return true;
    }

    const wsSessionRawMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/raw\/(.+)$/);
    if (wsSessionRawMatch && method === "GET") {
      const requestedPath = decodeWorkspaceRoutePath(wsSessionRawMatch[3]);
      if (requestedPath === null) {
        helpers.error(res, 400, "Invalid file path encoding");
        return true;
      }

      await sessionFileHandlers.handleGetSessionRaw(
        wsSessionRawMatch[1],
        wsSessionRawMatch[2],
        requestedPath,
        res,
      );
      return true;
    }

    const wsSessionDiffMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/diff$/);
    if (wsSessionDiffMatch && method === "GET") {
      await handleGetSessionOverallDiff(wsSessionDiffMatch[1], wsSessionDiffMatch[2], url, res);
      return true;
    }

    const wsSessionEventsMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/events$/);
    if (wsSessionEventsMatch && method === "GET") {
      handleGetSessionEvents(wsSessionEventsMatch[1], wsSessionEventsMatch[2], url, res);
      return true;
    }

    const wsSessionMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)$/);
    if (wsSessionMatch) {
      if (method === "GET") {
        await handleGetSession(req, wsSessionMatch[1], wsSessionMatch[2], url, res);
        return true;
      }
      if (method === "DELETE") {
        await handleDeleteSession(wsSessionMatch[1], wsSessionMatch[2], res);
        return true;
      }
    }

    return false;
  };
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}
