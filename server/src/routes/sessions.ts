import type { IncomingMessage, ServerResponse } from "node:http";
import { requiredModelLaunchFailureMessage } from "../agent-launch-service.js";
import { SessionLifecycleError, SessionLifecycleService } from "../session-lifecycle-service.js";
import { type ChatAttachmentRef, type ServerMessage, type Session } from "../types.js";
import { safeErrorMessage } from "../log-utils.js";
import { createLogger } from "../logger.js";
import { decodeWorkspaceRoutePath } from "../file-serving-policy.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";
import { createSessionListRouteHandlers } from "./session-list-handlers.js";
import { createSessionTraceRouteHandlers } from "./session-trace-handlers.js";
import { WsMessageHandler } from "../ws-message-handler.js";
import { normalizeSessionWorktreeId, resolveWorkspaceWorktree } from "../worktrees.js";
import { isDeclaredControlSession } from "../control-session.js";
import { parseClientCommand } from "../session-command-parse.js";
import { isThinkingLevel } from "../thinking-levels.js";

const CONTROL_SESSION_DOMAINS = new Set(["agents", "schedules", "skills", "workspaces"] as const);
const CONTROL_SESSION_INTENTS = new Set(["create", "revise"] as const);

const log = createLogger({ base: { component: "route_sessions" } });

function parseWorkspaceSessionToolPolicy(body: {
  tools?: unknown;
  excludeTools?: unknown;
  noTools?: unknown;
}): {
  tools?: string[];
  excludeTools?: string[];
  noTools?: "all" | "builtin";
  error?: string;
} {
  const tools = parseOptionalStringArray(body.tools, "tools");
  if (typeof tools === "string") return { error: tools };
  const excludeTools = parseOptionalStringArray(body.excludeTools, "excludeTools");
  if (typeof excludeTools === "string") return { error: excludeTools };
  if (body.noTools !== undefined && body.noTools !== "all" && body.noTools !== "builtin") {
    return { error: "noTools must be all or builtin" };
  }
  return {
    ...(tools ? { tools } : {}),
    ...(excludeTools ? { excludeTools } : {}),
    ...(body.noTools === "all" || body.noTools === "builtin" ? { noTools: body.noTools } : {}),
  };
}

function parseOptionalStringArray(value: unknown, field: string): string[] | string | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    return `${field} must be an array of strings`;
  }
  return value;
}

function invalidDelegationFields(
  parentSessionId: unknown,
  allowNestedDelegation: unknown,
): string | undefined {
  if (
    parentSessionId !== undefined &&
    (typeof parentSessionId !== "string" || !parentSessionId.trim())
  ) {
    return "parentSessionId must be a non-empty string";
  }
  if (allowNestedDelegation !== undefined && typeof allowNestedDelegation !== "boolean") {
    return "allowNestedDelegation must be a boolean";
  }
  return undefined;
}

export function createSessionRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  const lifecycle = new SessionLifecycleService({
    storage: ctx.storage,
    sessions: ctx.sessions,
    sessionRuntimes: ctx.sessionRuntimes,
    ensureSessionContextWindow: ctx.ensureSessionContextWindow,
    deleteSearchIndexSession: (sessionId) => ctx.searchIndex?.deleteSession(sessionId),
  });
  const commandHandler = new WsMessageHandler({
    sessions: ctx.sessionRuntimes,
    ensureSessionContextWindow: ctx.ensureSessionContextWindow,
  });
  const {
    handleSearchSessions,
    handleWorkspaceAttention,
    handleListRecentWorkspaceSessionSummaries,
    handleWorkspaceSessionBuckets,
    handleWorkspaceSessionCollection,
    handleGenericSessionCollection,
  } = createSessionListRouteHandlers(ctx, helpers);
  const {
    sessionFileHandlers,
    handleGetFullToolOutput,
    handleGetSessionAttachment,
    handleGetToolOutput,
    handleGetSessionOverallDiff,
    handleGetSessionEvents,
    handleGetSession,
    handleGetSessionTracePage,
    handleGetSessionTraceOutline,
    handleGenericGetSession,
    handleGenericGetSessionTrace,
    handleGenericGetSessionDialogs,
    handleGenericGetSessionEvents,
    handleGetFullToolOutputForSession,
    handleGetToolOutputForSession,
    handleGetSessionEventsForSession,
    handleGetSessionForSession,
    handleGetSessionTracePageForSession,
    handleGetSessionTraceOutlineForSession,
  } = createSessionTraceRouteHandlers(ctx, helpers, requireWorkspaceSession, requireSession);
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

  function requireControlSession(sessionId: string, res: ServerResponse): Session | null {
    const session = ctx.storage.getSession(sessionId);
    if (!session) {
      helpers.error(res, 404, "Session not found");
      return null;
    }
    if (!isDeclaredControlSession(session)) {
      helpers.error(res, 400, "Session is not a control session");
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
      tools?: unknown;
      excludeTools?: unknown;
      noTools?: unknown;
      ephemeral?: boolean;
      worktreeId?: string;
      attachments?: ChatAttachmentRef[];
      images?: unknown;
      idempotencyKey?: string;
      launchIdempotencyKey?: string;
      launchLeaseOwner?: string;
      parentSessionId?: string;
      allowNestedDelegation?: boolean;
    }>(req);
    const delegationFieldError = invalidDelegationFields(
      body.parentSessionId,
      body.allowNestedDelegation,
    );
    if (delegationFieldError) {
      helpers.error(res, 400, delegationFieldError);
      return;
    }
    if (Array.isArray(body.images) && body.images.length > 0) {
      helpers.error(
        res,
        400,
        "Raw base64 image transport is not supported; upload images as chat attachments first",
      );
      return;
    }
    if (body.thinking !== undefined && !isThinkingLevel(body.thinking)) {
      helpers.error(res, 400, "Invalid thinking level");
      return;
    }
    const toolPolicy = parseWorkspaceSessionToolPolicy(body);
    if (toolPolicy.error) {
      helpers.error(res, 400, toolPolicy.error);
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
        tools: toolPolicy.tools,
        excludeTools: toolPolicy.excludeTools,
        noTools: toolPolicy.noTools,
        ephemeral: body.ephemeral,
        worktreeId: worktreeSelection.worktreeId,
        attachments: body.attachments,
        idempotencyKey: body.launchIdempotencyKey ?? body.idempotencyKey,
        leaseOwner: body.launchLeaseOwner,
        parentSessionId: body.parentSessionId,
        allowNestedDelegation: body.allowNestedDelegation === true,
      });
      const requiredModelFailure = requiredModelLaunchFailureMessage(result.session);
      if (requiredModelFailure) {
        if (result.launchKind !== "existing") {
          ctx.appEvents?.emitSessionCreated(result.session);
        }
        helpers.json(res, { error: requiredModelFailure, sessionId: result.session.id }, 409);
        return;
      }
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

  async function handleCreateControlSession(
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await helpers.parseBody<{
      domain?: unknown;
      intent?: unknown;
      targetId?: unknown;
      targetName?: unknown;
      name?: unknown;
      model?: unknown;
      thinking?: unknown;
      prompt?: unknown;
      launchIdempotencyKey?: unknown;
    }>(req);
    if (
      typeof body.domain !== "string" ||
      !CONTROL_SESSION_DOMAINS.has(
        body.domain as "agents" | "schedules" | "skills" | "workspaces",
      ) ||
      typeof body.intent !== "string" ||
      !CONTROL_SESSION_INTENTS.has(body.intent as "create" | "revise") ||
      (body.targetId !== undefined &&
        (typeof body.targetId !== "string" || !body.targetId.trim())) ||
      (body.targetName !== undefined &&
        (typeof body.targetName !== "string" || !body.targetName.trim())) ||
      (body.name !== undefined && typeof body.name !== "string") ||
      (body.model !== undefined && (typeof body.model !== "string" || !body.model.trim())) ||
      (body.thinking !== undefined &&
        (typeof body.thinking !== "string" || !isThinkingLevel(body.thinking))) ||
      (body.prompt !== undefined && typeof body.prompt !== "string") ||
      (body.launchIdempotencyKey !== undefined &&
        (typeof body.launchIdempotencyKey !== "string" || !body.launchIdempotencyKey.trim()))
    ) {
      helpers.error(res, 400, "Invalid control session metadata");
      return;
    }

    const targetId = body.targetId?.trim();
    const targetName = body.targetName?.trim();
    try {
      const result = await lifecycle.createControlSession({
        control: {
          domain: body.domain as "agents" | "schedules" | "skills" | "workspaces",
          intent: body.intent as "create" | "revise",
          ...(targetId ? { targetId } : {}),
          ...(targetName ? { targetName } : {}),
        },
        name: body.name,
        model: typeof body.model === "string" ? body.model.trim() : undefined,
        thinking: typeof body.thinking === "string" ? body.thinking : undefined,
        prompt: body.prompt,
        idempotencyKey:
          typeof body.launchIdempotencyKey === "string"
            ? body.launchIdempotencyKey.trim()
            : undefined,
      });
      const requiredModelFailure = requiredModelLaunchFailureMessage(result.session);
      if (requiredModelFailure) {
        if (result.launchKind !== "existing") {
          ctx.appEvents?.emitSessionCreated(result.session);
        }
        helpers.json(res, { error: requiredModelFailure, sessionId: result.session.id }, 409);
        return;
      }
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

  function requireGenericMutableSession(sessionId: string, res: ServerResponse): Session | null {
    const session = requireSession(sessionId, res);
    if (!session) return null;
    if (isDeclaredControlSession(session)) {
      helpers.error(res, 400, "Use the control-session route for control-session mutations");
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
    const parsed = parseClientCommand(body);
    if (!parsed.ok) {
      if (parsed.code === "not_object") {
        helpers.error(res, 400, "Command body must be an object");
        return;
      }
      if (parsed.code === "missing_type") {
        helpers.error(res, 400, "Command type required");
        return;
      }
      if (parsed.code === "unknown_type") {
        helpers.json(res, {
          messages: [
            {
              type: "command_result",
              command: parsed.command,
              requestId: parsed.requestId,
              success: false,
              error: parsed.error,
            },
          ],
        });
        return;
      }
      helpers.error(res, 400, parsed.error);
      return;
    }

    const messages: ServerMessage[] = [];
    try {
      await commandHandler.handleClientMessage(
        session,
        parsed.message,
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
      if (err instanceof SessionLifecycleError) {
        helpers.error(res, err.statusCode, message);
        return;
      }
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

  async function handleGenericSessionCommand(
    sessionId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const session = requireGenericMutableSession(sessionId, res);
    if (!session) return;
    await dispatchSessionCommand(session, req, res);
  }

  async function handleGenericStopSession(sessionId: string, res: ServerResponse): Promise<void> {
    const session = requireGenericMutableSession(sessionId, res);
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

    await deleteKnownSession(session, res);
  }

  async function deleteKnownSession(session: Session, res: ServerResponse): Promise<void> {
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
    if (path === "/control-sessions" && method === "POST") {
      await handleCreateControlSession(req, res);
      return true;
    }

    const controlCommandMatch = path.match(/^\/control-sessions\/([^/]+)\/command$/);
    if (controlCommandMatch && method === "POST") {
      const session = requireControlSession(controlCommandMatch[1], res);
      if (session) await dispatchSessionCommand(session, req, res);
      return true;
    }

    const controlStopMatch = path.match(/^\/control-sessions\/([^/]+)\/stop$/);
    if (controlStopMatch && method === "POST") {
      const session = requireControlSession(controlStopMatch[1], res);
      if (session) await stopKnownSession(session, res);
      return true;
    }

    const controlResumeMatch = path.match(/^\/control-sessions\/([^/]+)\/resume$/);
    if (controlResumeMatch && method === "POST") {
      const session = requireControlSession(controlResumeMatch[1], res);
      if (!session) return true;
      try {
        const result = await lifecycle.resumeControlSession(session);
        helpers.json(res, { session: result.session });
      } catch (error: unknown) {
        const status = error instanceof SessionLifecycleError ? error.statusCode : 500;
        helpers.error(res, status, safeErrorMessage(error));
      }
      return true;
    }

    const controlEventsMatch = path.match(/^\/control-sessions\/([^/]+)\/events$/);
    if (controlEventsMatch && method === "GET") {
      const session = requireControlSession(controlEventsMatch[1], res);
      if (session) handleGetSessionEventsForSession(session, url, res);
      return true;
    }

    const controlTracePageMatch = path.match(/^\/control-sessions\/([^/]+)\/trace-page$/);
    if (controlTracePageMatch && method === "GET") {
      const session = requireControlSession(controlTracePageMatch[1], res);
      if (session) await handleGetSessionTracePageForSession(req, session, url, res);
      return true;
    }

    const controlTraceOutlineMatch = path.match(/^\/control-sessions\/([^/]+)\/trace-outline$/);
    if (controlTraceOutlineMatch && method === "GET") {
      const session = requireControlSession(controlTraceOutlineMatch[1], res);
      if (session) await handleGetSessionTraceOutlineForSession(req, session, res);
      return true;
    }

    const controlToolOutputMatch = path.match(
      /^\/control-sessions\/([^/]+)\/tool-output\/([^/]+)$/,
    );
    if (controlToolOutputMatch && method === "GET") {
      const session = requireControlSession(controlToolOutputMatch[1], res);
      if (session) {
        if (url.searchParams.get("full") === "true") {
          await handleGetFullToolOutputForSession(session, controlToolOutputMatch[2], req, res);
        } else {
          await handleGetToolOutputForSession(session, controlToolOutputMatch[2], req, res);
        }
      }
      return true;
    }

    const controlAttachmentMatch = path.match(
      /^\/control-sessions\/([^/]+)\/attachments\/([^/]+)$/,
    );
    if (controlAttachmentMatch && (method === "GET" || method === "HEAD")) {
      const session = requireControlSession(controlAttachmentMatch[1], res);
      if (session) {
        await handleGetSessionAttachment(session.id, controlAttachmentMatch[2], req, res, method);
      }
      return true;
    }

    const controlSessionMatch = path.match(/^\/control-sessions\/([^/]+)$/);
    if (controlSessionMatch) {
      const session = requireControlSession(controlSessionMatch[1], res);
      if (!session) return true;
      if (method === "GET") {
        await handleGetSessionForSession(req, session, url, res);
        return true;
      }
      if (method === "DELETE") {
        await deleteKnownSession(session, res);
        return true;
      }
    }

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

    const sessionDialogsMatch = path.match(/^\/sessions\/([^/]+)\/dialogs$/);
    if (sessionDialogsMatch && method === "GET") {
      handleGenericGetSessionDialogs(sessionDialogsMatch[1], res);
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

    const sessionAttachmentMatch = path.match(/^\/sessions\/([^/]+)\/attachments\/([^/]+)$/);
    if (sessionAttachmentMatch && (method === "GET" || method === "HEAD")) {
      await handleGetSessionAttachment(
        sessionAttachmentMatch[1],
        sessionAttachmentMatch[2],
        req,
        res,
        method,
      );
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
    if (wsSessionRawMatch && (method === "GET" || method === "HEAD")) {
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
        req,
        method,
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
