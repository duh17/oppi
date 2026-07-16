import type { IncomingMessage, ServerResponse } from "node:http";
import { performance } from "node:perf_hooks";
import { gzipSync } from "node:zlib";
import { SessionTraceService, type SessionTraceViewMode } from "../session-trace-service.js";
import type { Session } from "../types.js";
import { getSessionAttachment, streamSessionAttachment } from "../session-attachments.js";
import { pendingDialogSnapshots } from "../session-attention.js";
import { createSessionFileHandlers } from "./session-files.js";
import type { RouteContext, RouteHelpers } from "./types.js";

type RequireWorkspaceSession = (
  workspaceId: string,
  sessionId: string,
  res: ServerResponse,
) => Session | null;
type RequireSession = (sessionId: string, res: ServerResponse) => Session | null;

type SessionTraceRouteHandlers = {
  sessionFileHandlers: ReturnType<typeof createSessionFileHandlers>;
  handleGetFullToolOutput: (
    workspaceId: string,
    sessionId: string,
    toolCallId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ) => Promise<void>;
  handleGetSessionAttachment: (
    sessionId: string,
    attachmentId: string,
    req: IncomingMessage,
    res: ServerResponse,
    method: string,
  ) => Promise<void>;
  handleGetToolOutput: (
    workspaceId: string,
    sessionId: string,
    toolCallId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ) => Promise<void>;
  handleGetSessionOverallDiff: (
    workspaceId: string,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ) => Promise<void>;
  handleGetSessionEvents: (
    workspaceId: string,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ) => void;
  handleGetSession: (
    req: IncomingMessage,
    workspaceId: string,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ) => Promise<void>;
  handleGetSessionTracePage: (
    req: IncomingMessage,
    workspaceId: string,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ) => Promise<void>;
  handleGetSessionTraceOutline: (
    req: IncomingMessage,
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ) => Promise<void>;
  handleGenericGetSession: (sessionId: string, res: ServerResponse) => Promise<void>;
  handleGenericGetSessionTrace: (
    req: IncomingMessage,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ) => Promise<void>;
  handleGenericGetSessionDialogs: (sessionId: string, res: ServerResponse) => void;
  handleGenericGetSessionEvents: (sessionId: string, url: URL, res: ServerResponse) => void;
};

export function createSessionTraceRouteHandlers(
  ctx: RouteContext,
  helpers: RouteHelpers,
  requireWorkspaceSession: RequireWorkspaceSession,
  requireSession: RequireSession,
): SessionTraceRouteHandlers {
  const traceService = new SessionTraceService({
    storage: ctx.storage,
    sessionRuntimes: ctx.sessionRuntimes,
    ensureSessionContextWindow: ctx.ensureSessionContextWindow,
  });
  const sessionFileHandlers = createSessionFileHandlers(ctx, helpers, traceService);

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

  function writeSessionEvents(sessionId: string, url: URL, res: ServerResponse): void {
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

  function handleGetSessionEvents(
    workspaceId: string,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): void {
    if (!requireWorkspaceSession(workspaceId, sessionId, res)) return;
    writeSessionEvents(sessionId, url, res);
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
    if (!url.searchParams.has("cursor") && result.page.staleCursor) {
      helpers.error(res, 409, "Session trace is not synchronized with the active tree leaf");
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

  function handleGenericGetSessionDialogs(sessionId: string, res: ServerResponse): void {
    if (!requireSession(sessionId, res)) return;

    const dialogs = pendingDialogSnapshots(
      ctx.sessionRuntimes.getPendingUIRequestMessages(sessionId),
    );
    helpers.json(res, { dialogs, serverNow: Date.now() });
  }

  function handleGenericGetSessionEvents(sessionId: string, url: URL, res: ServerResponse): void {
    if (!requireSession(sessionId, res)) return;
    writeSessionEvents(sessionId, url, res);
  }

  return {
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
  };
}
