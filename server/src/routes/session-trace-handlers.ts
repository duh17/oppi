import type { IncomingMessage, ServerResponse } from "node:http";
import { performance } from "node:perf_hooks";
import { gzipSync } from "node:zlib";
import {
  SessionTraceService,
  type SessionOverallDiffResult,
  type SessionTraceViewMode,
} from "../session-trace-service.js";
import { admitSessionRoute } from "../session-route-scope.js";
import { InternalUrlNotFound } from "../internal-urls.js";
import type { Session, SessionEventsResponse } from "../types.js";
import { getSessionAttachment, streamSessionAttachment } from "../session-attachments.js";
import { streamFullToolOutputSidecar } from "../tool-output-sidecar.js";
import { pendingDialogSnapshots } from "../session-attention.js";
import { createSessionFileHandlers } from "./session-files.js";
import type { RouteContext, RouteHelpers } from "./types.js";

function decodeToolCallId(toolCallId: string): string {
  try {
    return decodeURIComponent(toolCallId);
  } catch {
    return toolCallId;
  }
}

type SessionTraceRouteHandlers = {
  handleGetInputCardOutput: (
    session: Session,
    entryId: string,
    res: ServerResponse,
  ) => Promise<void>;
  handleGetInternalUrl: (session: Session, url: URL, res: ServerResponse) => Promise<void>;
  handleStopInternalUrl: (session: Session, url: URL, res: ServerResponse) => Promise<void>;
  sessionFileHandlers: ReturnType<typeof createSessionFileHandlers>;
  handleGetSessionAttachment: (
    sessionId: string,
    attachmentId: string,
    req: IncomingMessage,
    res: ServerResponse,
    method: string,
  ) => Promise<void>;
  handleGetSessionOverallDiff: (session: Session, url: URL, res: ServerResponse) => Promise<void>;
  handleGenericGetSession: (sessionId: string, res: ServerResponse) => Promise<void>;
  handleGenericGetSessionTrace: (
    req: IncomingMessage,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ) => Promise<void>;
  handleGenericGetSessionDialogs: (sessionId: string, res: ServerResponse) => void;
  handleGenericGetSessionEvents: (
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ) => Promise<void>;
  handleGetFullToolOutputForSession: (
    session: Session,
    toolCallId: string,
    req: IncomingMessage,
    res: ServerResponse,
    method?: string,
  ) => Promise<void>;
  handleGetToolOutputForSession: (
    session: Session,
    toolCallId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ) => Promise<void>;
  handleGetSessionEventsForSession: (
    session: Session,
    url: URL,
    res: ServerResponse,
  ) => Promise<void>;
  handleGetSessionForSession: (
    req: IncomingMessage,
    session: Session,
    url: URL,
    res: ServerResponse,
  ) => Promise<void>;
  handleGetSessionTracePageForSession: (
    req: IncomingMessage,
    session: Session,
    url: URL,
    res: ServerResponse,
  ) => Promise<void>;
  handleGetSessionTraceOutlineForSession: (
    req: IncomingMessage,
    session: Session,
    res: ServerResponse,
  ) => Promise<void>;
};

export function createSessionTraceRouteHandlers(
  ctx: RouteContext,
  helpers: RouteHelpers,
): SessionTraceRouteHandlers {
  const traceService = new SessionTraceService({
    storage: ctx.storage,
    sessionRuntimes: ctx.sessionRuntimes,
    ensureSessionContextWindow: ctx.ensureSessionContextWindow,
    mobileRenderers: ctx.sessions.mobileRenderer,
    getMcpServerNames: (session) => ctx.mcp?.configuredServerNames(session.workspaceId) ?? [],
  });
  const sessionFileHandlers = createSessionFileHandlers(ctx, helpers, traceService);

  function requireSession(sessionId: string, res: ServerResponse): Session | null {
    const result = admitSessionRoute(ctx.storage, { scope: "generic", sessionId });
    if (result.kind === "ok") return result.session;
    helpers.error(res, 404, "Session not found");
    return null;
  }

  async function handleGetInputCardOutput(
    session: Session,
    entryId: string,
    res: ServerResponse,
  ): Promise<void> {
    const result = await ctx.sessionRuntimes.getServerDurableInputCardOutput(
      session.id,
      decodeToolCallId(entryId),
    );
    if (!result) {
      helpers.error(res, 404, "Card output not found");
      return;
    }
    helpers.json(res, result);
  }

  // ─── Internal URLs (`?url=proc://bash-3`) ───

  /** The `url` query, or a 400 answered. */
  function internalUrlParam(url: URL, res: ServerResponse): string | undefined {
    const value = url.searchParams.get("url");
    if (!value) helpers.error(res, 400, "url is required");
    return value || undefined;
  }

  /** A URL no viewer shows, or that names nothing, is a 404 that says which. */
  async function answerInternalUrl<T>(
    res: ServerResponse,
    run: () => Promise<T>,
  ): Promise<T | undefined> {
    try {
      return await run();
    } catch (error) {
      if (!(error instanceof InternalUrlNotFound)) throw error;
      helpers.error(res, 404, error.message);
      return undefined;
    }
  }

  async function handleGetInternalUrl(
    session: Session,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const target = internalUrlParam(url, res);
    if (!target) return;
    const fromParam = url.searchParams.get("from");
    const from = fromParam === null ? undefined : Number(fromParam);
    if (from !== undefined && (!Number.isSafeInteger(from) || from < 0)) {
      helpers.error(res, 400, "from must be a non-negative integer");
      return;
    }
    const answered = await answerInternalUrl(res, async () => ({
      view: await ctx.sessionRuntimes.viewInternalUrl(session.id, target, from),
    }));
    if (!answered) return;
    if (!answered.view) {
      helpers.error(res, 404, "This session has no internal URLs");
      return;
    }
    helpers.json(res, answered.view);
  }

  async function handleStopInternalUrl(
    session: Session,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const target = internalUrlParam(url, res);
    if (!target) return;
    const answered = await answerInternalUrl(res, async () => ({
      refusal: await ctx.sessionRuntimes.stopInternalUrl(session.id, target),
    }));
    if (!answered) return;
    if (answered.refusal === null) {
      helpers.error(res, 404, "This session has no internal URLs");
      return;
    }
    if (answered.refusal !== undefined) {
      helpers.error(res, 409, answered.refusal);
      return;
    }
    helpers.json(res, { ok: true });
  }

  // ─── Tool Output by ID ───

  async function handleGetFullToolOutputForSession(
    session: Session,
    toolCallId: string,
    req: IncomingMessage,
    res: ServerResponse,
    method = "GET",
  ): Promise<void> {
    const toolCallIdDecoded = decodeToolCallId(toolCallId);
    const wantsRawSidecar = method.toUpperCase() === "HEAD" || Boolean(req.headers?.range);
    if (wantsRawSidecar) {
      const sidecar = await traceService.statFullToolOutput(session.id, toolCallIdDecoded);
      if (sidecar) {
        streamFullToolOutputSidecar(sidecar, req, res, method);
        return;
      }
      const snapshot = await traceService.getFullToolOutput(session.id, toolCallIdDecoded);
      if (!snapshot) {
        helpers.error(res, 404, "Full tool output not found");
        return;
      }
      streamFullToolOutputSidecar(
        { text: snapshot.output, size: Buffer.byteLength(snapshot.output, "utf8") },
        req,
        res,
        method,
      );
      return;
    }

    const output = await traceService.getFullToolOutput(session.id, toolCallIdDecoded);
    if (!output) {
      helpers.error(res, 404, "Full tool output not found");
      return;
    }

    helpers.compressedJson(req, res, output);
  }

  async function handleGetSessionAttachment(
    sessionId: string,
    attachmentId: string,
    req: IncomingMessage,
    res: ServerResponse,
    method: string,
  ): Promise<void> {
    const session = requireSession(sessionId, res);
    if (!session) return;

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

  async function handleGetToolOutputForSession(
    session: Session,
    toolCallId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const output = await traceService.getToolOutput(session, decodeToolCallId(toolCallId));
    if (!output) {
      helpers.error(res, 404, "Tool output not found");
      return;
    }

    helpers.compressedJson(req, res, output);
  }

  async function handleGetSessionOverallDiff(
    session: Session,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const reqPath = url.searchParams.get("path")?.trim();
    if (!reqPath) {
      helpers.error(res, 400, "path parameter required");
      return;
    }

    writeSessionDiff(res, await traceService.getSessionOverallDiff({ session, path: reqPath }));
  }

  function writeSessionDiff(res: ServerResponse, result: SessionOverallDiffResult): void {
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

  async function writeSessionEvents(
    session: Session,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const sinceParam = url.searchParams.get("since");
    const sinceSeq = sinceParam ? Number.parseInt(sinceParam, 10) : 0;
    if (!Number.isFinite(sinceSeq) || sinceSeq < 0) {
      helpers.error(res, 400, "since must be a non-negative integer");
      return;
    }

    // A `ready` session whose background job or child will start its next turn is not settled;
    // `oppi session wait` reads this. Ask before reading the ring: the check awaits the runtime,
    // and the ring read, the live session, and the response must stay one synchronous snapshot.
    // A stale `true` only holds a wait one more poll; a stale `false` could drop the final
    // message. A stored, not-live session has no wakers.
    const pendingWake = await ctx.sessionRuntimes.awaitsNextTurn(session.id);
    const catchUp = ctx.sessionRuntimes.getCatchUp(session.id, sinceSeq);
    // No ring means the session is stored but not live. 404 stays reserved for a
    // session that does not exist; callers already checked that.
    const body: SessionEventsResponse = catchUp
      ? {
          events: catchUp.events,
          currentSeq: catchUp.currentSeq,
          ...(catchUp.runtimeEpoch ? { runtimeEpoch: catchUp.runtimeEpoch } : {}),
          session: {
            ...ctx.ensureSessionContextWindow(catchUp.session),
            ...(pendingWake ? { pendingWake: true as const } : {}),
          },
          catchUpComplete: catchUp.catchUpComplete,
          live: true,
        }
      : {
          events: [],
          currentSeq: 0,
          session: ctx.ensureSessionContextWindow(session),
          catchUpComplete: false,
          live: false,
        };
    helpers.json(res, body);
  }

  function handleGetSessionEventsForSession(
    session: Session,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    return writeSessionEvents(session, url, res);
  }

  function resolveTraceView(url: URL): SessionTraceViewMode {
    const view = url.searchParams.get("view");
    return view === "full" ? "full" : "context";
  }

  async function handleGetSessionForSession(
    req: IncomingMessage,
    session: Session,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const result = await traceService.getSessionWithTrace({
      session,
      traceView: resolveTraceView(url),
      includePresentationSegments: true,
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

  async function handleGetSessionTracePageForSession(
    req: IncomingMessage,
    session: Session,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
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
      includePresentationSegments: url.searchParams.get("presentation") === "mobile",
    });
    if (!result) {
      helpers.error(res, 404, "Session trace not found");
      return;
    }
    if (!url.searchParams.has("cursor") && result.page.staleCursor) {
      helpers.error(res, 409, "Session trace is not synchronized with the active tree leaf");
      return;
    }
    // The cards this page's tracked layouts writes make, derived again on every load.
    const layoutProposals =
      (await ctx.sessions.layoutFiles?.proposalsForTrace(session, result.trace)) ?? [];
    helpers.compressedJson(
      req,
      res,
      attachTracePageResponseMetrics(
        layoutProposals.length > 0 ? { ...result, layoutProposals } : result,
      ),
    );
  }

  async function handleGetSessionTraceOutlineForSession(
    req: IncomingMessage,
    session: Session,
    res: ServerResponse,
  ): Promise<void> {
    const result = await traceService.getSessionTraceOutline({ session });
    helpers.compressedJson(req, res, attachTracePageResponseMetrics(result));
  }

  async function handleGenericGetSession(sessionId: string, res: ServerResponse): Promise<void> {
    const session = requireSession(sessionId, res);
    if (!session) return;
    // Same live check `/events` makes: a `ready` session a running background job or child will
    // still wake is not settled. The subagent pill reads this to keep such a row Working.
    const pendingWake = await ctx.sessionRuntimes.awaitsNextTurn(session.id);
    helpers.json(res, {
      session: {
        ...ctx.ensureSessionContextWindow(session),
        ...(pendingWake ? { pendingWake: true as const } : {}),
      },
    });
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

  function handleGenericGetSessionDialogs(sessionId: string, res: ServerResponse): void {
    if (!requireSession(sessionId, res)) return;

    const dialogs = pendingDialogSnapshots(
      ctx.sessionRuntimes.getPendingUIRequestMessages(sessionId),
    );
    helpers.json(res, { dialogs, serverNow: Date.now() });
  }

  async function handleGenericGetSessionEvents(
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const session = requireSession(sessionId, res);
    if (!session) return;
    await writeSessionEvents(session, url, res);
  }

  return {
    sessionFileHandlers,
    handleGetSessionAttachment,
    handleGetSessionOverallDiff,
    handleGenericGetSession,
    handleGenericGetSessionTrace,
    handleGenericGetSessionDialogs,
    handleGenericGetSessionEvents,
    handleGetFullToolOutputForSession,
    handleGetToolOutputForSession,
    handleGetInputCardOutput,
    handleGetInternalUrl,
    handleStopInternalUrl,
    handleGetSessionEventsForSession,
    handleGetSessionForSession,
    handleGetSessionTracePageForSession,
    handleGetSessionTraceOutlineForSession,
  };
}
