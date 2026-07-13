import type { IncomingMessage, ServerResponse } from "node:http";
import { SessionListService, type SessionStatusFilter } from "../session-list-service.js";
import type { Session } from "../types.js";
import { pendingAskSnapshots as collectPendingAskSnapshots } from "../session-attention.js";
import { normalizeSessionWorktreeId } from "../worktrees.js";
import type { RouteContext, RouteHelpers } from "./types.js";

type SessionListRouteHandlers = {
  handleSearchSessions: (url: URL, res: ServerResponse) => void;
  handleWorkspaceAttention: (workspaceId: string, res: ServerResponse) => void;
  handleListRecentWorkspaceSessionSummaries: (req: IncomingMessage, res: ServerResponse) => void;
  handleWorkspaceSessionBuckets: (
    workspaceId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ) => void;
  handleWorkspaceSessionCollection: (
    workspaceId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ) => Promise<void>;
  handleGenericSessionCollection: (url: URL, res: ServerResponse) => void;
};

export function createSessionListRouteHandlers(
  ctx: RouteContext,
  helpers: RouteHelpers,
): SessionListRouteHandlers {
  const listService = new SessionListService({
    storage: ctx.storage,
    sessionRuntimes: ctx.sessionRuntimes,
    ensureSessionContextWindow: ctx.ensureSessionContextWindow,
  });

  /** Full-text search across session content. */
  function handleSearchSessions(url: URL, res: ServerResponse): void {
    if (!ctx.searchIndex) {
      helpers.error(res, 503, "Search index not available");
      return;
    }

    const query = url.searchParams.get("q")?.trim() ?? "";
    const timeRange = sessionSearchTimeRange(url);
    if (timeRange.error) {
      helpers.error(res, 400, timeRange.error);
      return;
    }

    if (!query && timeRange.sinceMs === undefined && timeRange.untilMs === undefined) {
      helpers.json(res, {
        results: [],
        query: "",
        totalResults: 0,
        sort: "relevance_then_recency",
      });
      return;
    }

    const workspaceId = url.searchParams.get("workspaceId") ?? undefined;
    const limit = Math.min(parseInt(url.searchParams.get("limit") ?? "20", 10) || 20, 100);
    const sort = query ? "relevance_then_recency" : "updated_at_desc";

    const results = ctx.searchIndex.search(query, workspaceId, limit, {
      sinceMs: timeRange.sinceMs,
      untilMs: timeRange.untilMs,
    });

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
      sort,
      ...(timeRange.sinceMs !== undefined ? { sinceMs: timeRange.sinceMs } : {}),
      ...(timeRange.untilMs !== undefined ? { untilMs: timeRange.untilMs } : {}),
    });
  }

  function sessionSearchTimeRange(url: URL): {
    sinceMs?: number;
    untilMs?: number;
    error?: string;
  } {
    const sinceRaw = url.searchParams.get("since") ?? url.searchParams.get("sinceMs") ?? undefined;
    const untilRaw = url.searchParams.get("until") ?? url.searchParams.get("untilMs") ?? undefined;
    const sinceMs = parseSessionSearchTimeBound(sinceRaw, false);
    const untilMs = parseSessionSearchTimeBound(untilRaw, true);
    if (sinceMs.error) return { error: sinceMs.error };
    if (untilMs.error) return { error: untilMs.error };
    if (
      sinceMs.value !== undefined &&
      untilMs.value !== undefined &&
      sinceMs.value > untilMs.value
    ) {
      return { error: "since must be before or equal to until" };
    }
    return {
      ...(sinceMs.value !== undefined ? { sinceMs: sinceMs.value } : {}),
      ...(untilMs.value !== undefined ? { untilMs: untilMs.value } : {}),
    };
  }

  function parseSessionSearchTimeBound(
    raw: string | undefined,
    isEnd: boolean,
  ): { value?: number; error?: string } {
    const trimmed = raw?.trim();
    if (!trimmed) return {};
    const numeric = Number.parseInt(trimmed, 10);
    if (/^\d+$/.test(trimmed) && Number.isFinite(numeric)) {
      return { value: numeric };
    }

    const dateOnly = trimmed.match(/^(\d{4})-(\d{2})-(\d{2})$/);
    if (dateOnly) {
      const year = Number.parseInt(dateOnly[1] ?? "", 10);
      const monthIndex = Number.parseInt(dateOnly[2] ?? "", 10) - 1;
      const day = Number.parseInt(dateOnly[3] ?? "", 10);
      const date = new Date(year, monthIndex, day, 0, 0, 0, 0);
      if (
        Number.isNaN(date.getTime()) ||
        date.getFullYear() !== year ||
        date.getMonth() !== monthIndex ||
        date.getDate() !== day
      ) {
        return { error: `invalid session search date: ${trimmed}` };
      }
      if (!isEnd) return { value: date.getTime() };
      date.setDate(date.getDate() + 1);
      return { value: date.getTime() - 1 };
    }

    const ms = Date.parse(trimmed);
    if (Number.isNaN(ms)) {
      return { error: `invalid session search timestamp: ${trimmed}` };
    }
    return { value: ms };
  }

  function pendingAskSnapshots(workspaceId: string): Array<Record<string, unknown>> {
    return collectPendingAskSnapshots(ctx.sessionRuntimes, workspaceId);
  }

  function workspaceAttentionSnapshot(workspaceId: string): {
    asks: Array<Record<string, unknown>>;
  } {
    return {
      asks: pendingAskSnapshots(workspaceId),
    };
  }

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
      attention: workspaceAttentionSnapshot(workspaceId),
    });
  }

  function handleListRecentWorkspaceSessionSummaries(
    req: IncomingMessage,
    res: ServerResponse,
  ): void {
    const url = new URL(req.url ?? "/", "http://localhost");
    const recentDaysParam = Number.parseInt(url.searchParams.get("recentDays") ?? "", 10);
    const recentDays =
      Number.isFinite(recentDaysParam) && recentDaysParam > 0 ? recentDaysParam : 0;
    const piSessionIdFilter = url.searchParams.get("piSessionId")?.trim();
    const serverNow = Date.now();

    helpers.compressedJson(
      req,
      res,
      listService.listRecentWorkspaceSessionSummaries({
        recentDays,
        ...(piSessionIdFilter ? { piSessionId: piSessionIdFilter } : {}),
        nowMs: serverNow,
      }),
    );
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

    const worktreeSelection = normalizeSessionWorktreeId(
      workspace,
      url.searchParams.get("worktreeId") ?? undefined,
      { dataDir: ctx.storage.getDataDir() },
    );
    if (worktreeSelection.error) {
      helpers.error(res, 400, worktreeSelection.error);
      return;
    }

    helpers.compressedJson(
      req,
      res,
      listService.listWorkspaceStoppedSessionBuckets({
        workspace,
        beforeMs,
        worktreeId: worktreeSelection.worktreeId,
        nowMs: Date.now(),
      }),
    );
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

    const worktreeSelection = normalizeSessionWorktreeId(
      workspace,
      url.searchParams.get("worktreeId") ?? undefined,
      { dataDir: ctx.storage.getDataDir() },
    );
    if (worktreeSelection.error) {
      helpers.error(res, 400, worktreeSelection.error);
      return;
    }

    helpers.compressedJson(
      req,
      res,
      listService.listWorkspaceSessionRows({
        workspace,
        statuses: parsedStatus.statuses,
        ...(parsedTimeRange.timeRange ? { timeRange: parsedTimeRange.timeRange } : {}),
        worktreeId: worktreeSelection.worktreeId,
        nowMs: Date.now(),
      }),
    );
  }

  function handleGenericSessionCollection(url: URL, res: ServerResponse): void {
    const byId = new Map<string, Session>();
    for (const session of ctx.storage.listSessions()) {
      byId.set(session.id, session);
    }
    for (const activeSessionId of ctx.sessionRuntimes.getActiveSessionIds()) {
      const active = ctx.sessionRuntimes.getActiveSession(activeSessionId);
      if (active) byId.set(active.id, active);
    }

    const workspaceId = url.searchParams.get("workspaceId")?.trim();
    const worktreeId = url.searchParams.get("worktreeId")?.trim();
    const agentId = url.searchParams.get("agentId")?.trim();
    const statusFilter = url.searchParams
      .get("status")
      ?.split(",")
      .map((status) => status.trim())
      .filter(Boolean);
    const limitRaw = url.searchParams.get("limit")?.trim();
    const limit = limitRaw ? Number.parseInt(limitRaw, 10) : undefined;
    if (limit !== undefined && (!Number.isFinite(limit) || limit < 1)) {
      helpers.error(res, 400, "limit must be a positive integer");
      return;
    }

    let sessions = Array.from(byId.values());
    if (workspaceId) {
      sessions = sessions.filter((session) => session.workspaceId === workspaceId);
    }
    if (worktreeId) {
      sessions = sessions.filter((session) => (session.worktreeId ?? "main") === worktreeId);
    }
    if (agentId) {
      sessions = sessions.filter((session) => session.launch?.agentId === agentId);
    }
    if (statusFilter && statusFilter.length > 0) {
      sessions = sessions.filter((session) =>
        statusFilter.some((status) => {
          if (status === "active") return session.status !== "stopped";
          if (status === "stopped") return session.status === "stopped";
          return session.status === status;
        }),
      );
    }

    sessions = sessions
      .map((session) => ctx.ensureSessionContextWindow(session))
      .sort((lhs, rhs) => (rhs.lastActivity ?? 0) - (lhs.lastActivity ?? 0));
    if (limit !== undefined) {
      sessions = sessions.slice(0, limit);
    }

    helpers.json(res, { sessions, serverNow: Date.now() });
  }

  return {
    handleSearchSessions,
    handleWorkspaceAttention,
    handleListRecentWorkspaceSessionSummaries,
    handleWorkspaceSessionBuckets,
    handleWorkspaceSessionCollection,
    handleGenericSessionCollection,
  };
}
