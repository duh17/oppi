import type { IncomingMessage, ServerResponse } from "node:http";
import { performance } from "node:perf_hooks";
import { gzipSync } from "node:zlib";
import { SessionLifecycleError, SessionLifecycleService } from "../session-lifecycle-service.js";
import { SessionListService, type SessionStatusFilter } from "../session-list-service.js";
import { SessionTraceService, type SessionTraceViewMode } from "../session-trace-service.js";
import {
  type ChatAttachmentRef,
  type ClientMessage,
  type ServerMessage,
  type Session,
} from "../types.js";
import { safeErrorMessage } from "../log-utils.js";
import { createLogger } from "../logger.js";
import { getSessionAttachment, streamSessionAttachment } from "../session-attachments.js";
import { decodeWorkspaceRoutePath } from "../file-serving-policy.js";
import { createSessionFileHandlers } from "./session-files.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";
import { pendingAskSnapshots as collectPendingAskSnapshots } from "../session-attention.js";
import { WsMessageHandler } from "../ws-message-handler.js";
import { normalizeSessionWorktreeId, resolveWorkspaceWorktree } from "../worktrees.js";

const CREATE_SESSION_THINKING_LEVELS = new Set([
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
]);

const log = createLogger({ base: { component: "route_sessions" } });

export function createSessionRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  const lifecycle = new SessionLifecycleService({
    storage: ctx.storage,
    sessions: ctx.sessions,
    sessionRuntimes: ctx.sessionRuntimes,
    ensureSessionContextWindow: ctx.ensureSessionContextWindow,
    deleteSearchIndexSession: (sessionId) => ctx.searchIndex?.deleteSession(sessionId),
  });
  const listService = new SessionListService({
    storage: ctx.storage,
    sessionRuntimes: ctx.sessionRuntimes,
    ensureSessionContextWindow: ctx.ensureSessionContextWindow,
  });
  const traceService = new SessionTraceService({
    storage: ctx.storage,
    sessionRuntimes: ctx.sessionRuntimes,
    ensureSessionContextWindow: ctx.ensureSessionContextWindow,
  });
  const sessionFileHandlers = createSessionFileHandlers(ctx, helpers, traceService);
  const commandHandler = new WsMessageHandler({
    sessions: ctx.sessionRuntimes,
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
      ephemeral?: boolean;
      worktreeId?: string;
      attachments?: ChatAttachmentRef[];
      images?: unknown;
      idempotencyKey?: string;
      launchIdempotencyKey?: string;
      launchLeaseOwner?: string;
    }>(req);
    if (Array.isArray(body.images) && body.images.length > 0) {
      helpers.error(
        res,
        400,
        "Raw base64 image transport is not supported; upload images as chat attachments first",
      );
      return;
    }
    if (body.thinking !== undefined && !CREATE_SESSION_THINKING_LEVELS.has(body.thinking)) {
      helpers.error(res, 400, "Invalid thinking level");
      return;
    }
    const requestedModel = body.model;
    const worktreeSelection = normalizeSessionWorktreeId(workspace, body.worktreeId, {
      dataDir: ctx.storage.getDataDir(),
    });
    if (worktreeSelection.error) {
      helpers.error(res, 400, worktreeSelection.error);
      return;
    }

    // ── Local session import: validate path confinement + CWD alignment ──
    if (body.piSessionFile) {
      try {
        const selectedWorktree = resolveWorkspaceWorktree(workspace, worktreeSelection.worktreeId, {
          dataDir: ctx.storage.getDataDir(),
        });
        const importWorkspace = selectedWorktree
          ? { ...workspace, hostMount: selectedWorktree.path }
          : workspace;
        const result = await lifecycle.importLocalSession({
          workspace: importWorkspace,
          piSessionFile: body.piSessionFile,
          name: body.name,
          model: requestedModel,
          worktreeId: worktreeSelection.worktreeId,
        });
        ctx.searchIndex?.indexSession(result.session.id);
        ctx.appEvents?.emitSessionImported(result.session);
        helpers.json(res, { session: result.session }, result.created ? 201 : 200);
      } catch (error: unknown) {
        if (error instanceof SessionLifecycleError) {
          helpers.error(res, error.statusCode, error.message);
          return;
        }
        helpers.error(res, 500, safeErrorMessage(error));
      }
      return;
    }

    try {
      const result = await lifecycle.createWorkspaceSession({
        workspace,
        name: body.name,
        model: requestedModel,
        prompt: body.prompt,
        thinking: body.thinking,
        ephemeral: body.ephemeral,
        worktreeId: worktreeSelection.worktreeId,
        attachments: body.attachments,
        idempotencyKey: body.launchIdempotencyKey ?? body.idempotencyKey,
        leaseOwner: body.launchLeaseOwner,
      });
      if (result.launchKind !== "existing") {
        ctx.appEvents?.emitSessionCreated(result.createdSession);
      }
      if (result.summarySession) {
        ctx.appEvents?.emitSessionSummary(result.summarySession);
      }
      helpers.json(
        res,
        {
          session: result.session,
          ...(result.prompted !== undefined ? { prompted: result.prompted } : {}),
          ...(result.launchKind === "existing" ? { launch: { existing: true } } : {}),
        },
        result.launchKind === "existing" ? 200 : 201,
      );
    } catch (error: unknown) {
      if (error instanceof SessionLifecycleError) {
        if (error.message === "launch_in_progress") {
          helpers.json(res, { error: "launch_in_progress", retryable: true }, error.statusCode);
          return;
        }
        helpers.error(res, error.statusCode, error.message);
        return;
      }
      helpers.error(res, 500, safeErrorMessage(error));
    }
  }

  function requireSession(sessionId: string, res: ServerResponse): Session | null {
    const session = ctx.storage.getSession(sessionId);
    if (!session) {
      helpers.error(res, 404, "Session not found");
      return null;
    }

    return session;
  }

  async function dispatchSessionCommand(
    session: Session,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await helpers.parseBody<unknown>(req);
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      helpers.error(res, 400, "Command body must be an object");
      return;
    }
    const command = body as ClientMessage;
    if (typeof (command as { type?: unknown }).type !== "string") {
      helpers.error(res, 400, "Command type required");
      return;
    }

    const messages: ServerMessage[] = [];
    try {
      await commandHandler.handleClientMessage(
        session,
        command,
        (message) => messages.push(message),
        { connId: "http-session-command" },
      );
    } catch (error) {
      helpers.error(res, 500, safeErrorMessage(error));
      return;
    }

    helpers.json(res, { messages });
  }

  async function handleSessionCommand(
    workspaceId: string,
    sessionId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const session = requireWorkspaceSession(workspaceId, sessionId, res);
    if (!session) return;
    await dispatchSessionCommand(session, req, res);
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

    try {
      const result = await lifecycle.resumeWorkspaceSession({ session, workspace });
      helpers.json(res, { session: result.session });
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

    try {
      const result = await lifecycle.forkSession({
        workspace,
        sourceSession,
        entryId,
        name: body.name,
      });
      ctx.appEvents?.emitSessionCreated(result.session);
      helpers.json(res, { session: result.session }, 201);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Fork failed";
      if (err instanceof SessionLifecycleError) {
        helpers.error(res, err.statusCode, message);
        return;
      }

      log.error("sessions.fork.failed", {
        workspaceId,
        sourceSessionId,
        entryId,
        error: safeErrorMessage(err),
      });
      helpers.error(res, 500, message);
    }
  }

  async function stopKnownSession(session: Session, res: ServerResponse): Promise<void> {
    try {
      const result = await lifecycle.stopSession(session);
      if (result.storedStopOnly && result.session) {
        ctx.appEvents?.emitStopConfirmed(result.session, "user");
      }
      helpers.json(res, { ok: true, session: result.session });
    } catch (error: unknown) {
      helpers.error(res, 500, safeErrorMessage(error));
    }
  }

  async function handleStopSession(
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const session = requireWorkspaceSession(workspaceId, sessionId, res);
    if (!session) return;
    await stopKnownSession(session, res);
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

    const output = await traceService.getFullToolOutput(sessionId, toolCallId);
    if (!output) {
      helpers.error(res, 404, "Full tool output not found");
      return;
    }

    helpers.compressedJson(req, res, output);
  }

  async function handleGetSessionAttachment(
    workspaceId: string,
    sessionId: string,
    attachmentId: string,
    req: IncomingMessage,
    res: ServerResponse,
    method: string,
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

    streamSessionAttachment(attachment, req, res, method);
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

    const output = await traceService.getToolOutput(session, toolCallId);
    if (!output) {
      helpers.error(res, 404, "Tool output not found");
      return;
    }

    helpers.compressedJson(req, res, output);
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

    const result = await traceService.getSessionOverallDiff({ session, path: reqPath });
    switch (result.kind) {
      case "ok":
        helpers.json(res, result.diff);
        return;
      case "trace-not-found":
        helpers.error(res, 404, "Session trace not found");
        return;
      case "mutations-not-found":
        helpers.error(res, 404, "No file mutations found for path");
        return;
      case "workspace-root-not-found":
        helpers.error(res, 404, "Workspace root not found");
        return;
      case "current-file-not-found":
        helpers.error(res, 404, "Current file not found");
        return;
      case "current-file-outside-workspace":
        helpers.error(res, 403, "Current file path outside workspace");
        return;
      case "current-file-not-file":
        helpers.error(res, 400, "Current path is not a file");
        return;
      case "current-file-too-large":
        helpers.error(res, 413, `Current file too large (max ${result.maxSizeMegabytes}MB)`);
        return;
      case "current-file-unreadable":
        helpers.error(res, 500, "Failed to read current file");
        return;
    }
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

    const catchUp = ctx.sessionRuntimes.getCatchUp(sessionId, sinceSeq);
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

  function resolveTraceView(url: URL): SessionTraceViewMode {
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

    const result = await traceService.getSessionWithTrace({
      session,
      traceView: resolveTraceView(url),
    });
    helpers.compressedJson(req, res, result);
  }

  function positiveIntegerParam(url: URL, name: string): { value?: number; error?: string } {
    const raw = url.searchParams.get(name)?.trim();
    if (!raw) return {};
    const value = Number.parseInt(raw, 10);
    if (!Number.isFinite(value) || value < 1) {
      return { error: `${name} must be a positive integer` };
    }
    return { value };
  }

  function attachTracePageResponseMetrics<T extends { metrics: object }>(
    result: T,
  ): T & { metrics: T["metrics"] & Record<string, number> } {
    const stringifyStart = performance.now();
    const json = JSON.stringify(result);
    const stringifyMs = Math.round((performance.now() - stringifyStart) * 100) / 100;
    const gzipStart = performance.now();
    const gzipped = gzipSync(json, { level: 1 });
    const gzipMs = Math.round((performance.now() - gzipStart) * 100) / 100;
    return {
      ...result,
      metrics: {
        ...result.metrics,
        jsonBytes: Buffer.byteLength(json),
        stringifyMs,
        gzipBytes: gzipped.byteLength,
        gzipMs,
      },
    };
  }

  async function handleGetSessionTracePage(
    req: IncomingMessage,
    workspaceId: string,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const session = requireWorkspaceSession(workspaceId, sessionId, res);
    if (!session) return;

    const targetEvents = positiveIntegerParam(url, "targetEvents");
    if (targetEvents.error) {
      helpers.error(res, 400, targetEvents.error);
      return;
    }
    const previewBytes = positiveIntegerParam(url, "previewBytes");
    if (previewBytes.error) {
      helpers.error(res, 400, previewBytes.error);
      return;
    }

    const result = await traceService.getSessionTracePage({
      session,
      cursor: url.searchParams.get("cursor") ?? undefined,
      aroundEntryId: url.searchParams.get("aroundEntryId") ?? undefined,
      targetEvents: targetEvents.value,
      previewBytes: previewBytes.value,
    });
    if (!result) {
      helpers.error(res, 404, "Session trace not found");
      return;
    }
    helpers.compressedJson(req, res, attachTracePageResponseMetrics(result));
  }

  async function handleGetSessionTraceOutline(
    req: IncomingMessage,
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const session = requireWorkspaceSession(workspaceId, sessionId, res);
    if (!session) return;

    const result = await traceService.getSessionTraceOutline({ session });
    helpers.compressedJson(req, res, attachTracePageResponseMetrics(result));
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

  async function handleGenericGetSession(sessionId: string, res: ServerResponse): Promise<void> {
    const session = requireSession(sessionId, res);
    if (!session) return;
    helpers.json(res, { session: ctx.ensureSessionContextWindow(session) });
  }

  function traceTailFor(url: URL): { tail?: number; error?: string } {
    const raw = url.searchParams.get("tail")?.trim();
    if (!raw) return {};
    const tail = Number.parseInt(raw, 10);
    if (!Number.isFinite(tail) || tail < 0) {
      return { error: "tail must be a non-negative integer" };
    }
    return { tail };
  }

  type GenericTraceIncludePart = "all" | "messages" | "summary" | "system" | "thinking" | "tools";

  const genericTraceIncludeParts = new Set<GenericTraceIncludePart>([
    "all",
    "messages",
    "summary",
    "system",
    "thinking",
    "tools",
  ]);

  function traceIncludeFor(url: URL): { parts?: Set<GenericTraceIncludePart>; error?: string } {
    const raw = url.searchParams.get("include")?.trim();
    if (!raw) return {};

    const parts = new Set<GenericTraceIncludePart>();
    const invalid: string[] = [];
    for (const part of raw
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean)) {
      if (genericTraceIncludeParts.has(part as GenericTraceIncludePart)) {
        parts.add(part as GenericTraceIncludePart);
      } else {
        invalid.push(part);
      }
    }

    if (invalid.length > 0) {
      return {
        error: `include must contain only all, messages, summary, system, thinking, or tools`,
      };
    }
    if (parts.size === 0 || parts.has("all")) return {};
    return { parts };
  }

  function filterTraceByInclude<T extends { type?: string }>(
    trace: T[],
    parts: Set<GenericTraceIncludePart> | undefined,
  ): T[] {
    if (!parts) return trace;
    return trace.filter((event) => {
      if (parts.has("messages") && (event.type === "user" || event.type === "assistant")) {
        return true;
      }
      if (parts.has("summary") && event.type === "compaction") return true;
      if (parts.has("system") && event.type === "system") return true;
      if (parts.has("thinking") && event.type === "thinking") return true;
      if (parts.has("tools") && (event.type === "toolCall" || event.type === "toolResult")) {
        return true;
      }
      return false;
    });
  }

  async function handleGenericGetSessionTrace(
    req: IncomingMessage,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const session = requireSession(sessionId, res);
    if (!session) return;
    const tail = traceTailFor(url);
    if (tail.error) {
      helpers.error(res, 400, tail.error);
      return;
    }
    const include = traceIncludeFor(url);
    if (include.error) {
      helpers.error(res, 400, include.error);
      return;
    }

    const result = await traceService.getSessionWithTrace({ session, traceView: "full" });
    const includedTrace = filterTraceByInclude(result.trace, include.parts);
    const trace =
      tail.tail === undefined
        ? includedTrace
        : tail.tail === 0
          ? []
          : includedTrace.slice(-tail.tail);
    helpers.compressedJson(req, res, { ...result, trace });
  }

  function handleGenericGetSessionEvents(sessionId: string, url: URL, res: ServerResponse): void {
    const session = requireSession(sessionId, res);
    if (!session) return;

    const sinceParam = url.searchParams.get("since");
    const sinceSeq = sinceParam ? Number.parseInt(sinceParam, 10) : 0;
    if (!Number.isFinite(sinceSeq) || sinceSeq < 0) {
      helpers.error(res, 400, "since must be a non-negative integer");
      return;
    }

    const catchUp = ctx.sessionRuntimes.getCatchUp(sessionId, sinceSeq);
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

  async function handleGenericSessionCommand(
    sessionId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const session = requireSession(sessionId, res);
    if (!session) return;
    await dispatchSessionCommand(session, req, res);
  }

  async function handleGenericStopSession(sessionId: string, res: ServerResponse): Promise<void> {
    const session = requireSession(sessionId, res);
    if (!session) return;
    await stopKnownSession(session, res);
  }

  async function handleDeleteSession(
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const session = requireWorkspaceSession(workspaceId, sessionId, res);
    if (!session) return;

    try {
      const result = await lifecycle.deleteSession(session);
      ctx.appEvents?.emitSessionDeleted(result.session);
      helpers.json(res, { ok: true, deleted: result.deleted });
    } catch (error: unknown) {
      if (error instanceof SessionLifecycleError) {
        helpers.error(res, error.statusCode, error.message);
        return;
      }
      helpers.error(res, 500, safeErrorMessage(error));
    }
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

    if (path === "/sessions" && method === "GET") {
      handleGenericSessionCollection(url, res);
      return true;
    }

    const sessionCommandMatch = path.match(/^\/sessions\/([^/]+)\/command$/);
    if (sessionCommandMatch && method === "POST") {
      await handleGenericSessionCommand(sessionCommandMatch[1], req, res);
      return true;
    }

    const sessionStopMatch = path.match(/^\/sessions\/([^/]+)\/stop$/);
    if (sessionStopMatch && method === "POST") {
      await handleGenericStopSession(sessionStopMatch[1], res);
      return true;
    }

    const sessionEventsMatch = path.match(/^\/sessions\/([^/]+)\/events$/);
    if (sessionEventsMatch && method === "GET") {
      handleGenericGetSessionEvents(sessionEventsMatch[1], url, res);
      return true;
    }

    const sessionReadMatch = path.match(/^\/sessions\/([^/]+)\/read$/);
    if (sessionReadMatch && method === "GET") {
      await handleGenericGetSessionTrace(req, sessionReadMatch[1], url, res);
      return true;
    }

    const sessionTraceMatch = path.match(/^\/sessions\/([^/]+)\/trace$/);
    if (sessionTraceMatch && method === "GET") {
      await handleGenericGetSessionTrace(req, sessionTraceMatch[1], url, res);
      return true;
    }

    const sessionMatch = path.match(/^\/sessions\/([^/]+)$/);
    if (sessionMatch && method === "GET") {
      await handleGenericGetSession(sessionMatch[1], res);
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

    const wsSessionCommandMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/command$/);
    if (wsSessionCommandMatch && method === "POST") {
      await handleSessionCommand(wsSessionCommandMatch[1], wsSessionCommandMatch[2], req, res);
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
    if (wsSessionAttachmentMatch && (method === "GET" || method === "HEAD")) {
      await handleGetSessionAttachment(
        wsSessionAttachmentMatch[1],
        wsSessionAttachmentMatch[2],
        wsSessionAttachmentMatch[3],
        req,
        res,
        method,
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

    const wsSessionTracePageMatch = path.match(
      /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/trace-page$/,
    );
    if (wsSessionTracePageMatch && method === "GET") {
      await handleGetSessionTracePage(
        req,
        wsSessionTracePageMatch[1],
        wsSessionTracePageMatch[2],
        url,
        res,
      );
      return true;
    }

    const wsSessionTraceOutlineMatch = path.match(
      /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/trace-outline$/,
    );
    if (wsSessionTraceOutlineMatch && method === "GET") {
      await handleGetSessionTraceOutline(
        req,
        wsSessionTraceOutlineMatch[1],
        wsSessionTraceOutlineMatch[2],
        res,
      );
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
