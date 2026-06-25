import type { IncomingMessage, ServerResponse } from "node:http";
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

    helpers.compressedJson(
      req,
      res,
      listService.listWorkspaceStoppedSessionBuckets({
        workspace,
        beforeMs,
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

    helpers.compressedJson(
      req,
      res,
      listService.listWorkspaceSessionRows({
        workspace,
        statuses: parsedStatus.statuses,
        ...(parsedTimeRange.timeRange ? { timeRange: parsedTimeRange.timeRange } : {}),
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
      attachments?: ChatAttachmentRef[];
      images?: unknown;
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

    // ── Local session import: validate path confinement + CWD alignment ──
    if (body.piSessionFile) {
      try {
        const result = await lifecycle.importLocalSession({
          workspace,
          piSessionFile: body.piSessionFile,
          name: body.name,
          model: requestedModel,
        });
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
        attachments: body.attachments,
      });
      ctx.appEvents?.emitSessionCreated(result.createdSession);
      if (result.summarySession) {
        ctx.appEvents?.emitSessionSummary(result.summarySession);
      }
      helpers.json(
        res,
        {
          session: result.session,
          ...(result.prompted !== undefined ? { prompted: result.prompted } : {}),
        },
        201,
      );
    } catch (error: unknown) {
      if (error instanceof SessionLifecycleError) {
        helpers.error(res, error.statusCode, error.message);
        return;
      }
      helpers.error(res, 500, safeErrorMessage(error));
    }
  }

  async function handleSessionCommand(
    workspaceId: string,
    sessionId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const session = requireWorkspaceSession(workspaceId, sessionId, res);
    if (!session) return;

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

  async function handleStopSession(
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const session = requireWorkspaceSession(workspaceId, sessionId, res);
    if (!session) return;

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
