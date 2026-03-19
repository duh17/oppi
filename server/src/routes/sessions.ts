import type { IncomingMessage, ServerResponse } from "node:http";
import { createReadStream } from "node:fs";
import { access, appendFile, mkdir, readFile, realpath, stat } from "node:fs/promises";
import { extname, join, resolve } from "node:path";
import { homedir } from "node:os";

import { isPathWithinRoot } from "../git-utils.js";
import {
  readSessionTrace,
  readSessionTraceByUuid,
  readSessionTraceFromFile,
  readSessionTraceFromFiles,
  findToolOutput,
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
  invalidateLocalSessionsCache,
  validateLocalSessionPath,
  validateCwdAlignment,
} from "../local-sessions.js";
import {
  telemetryUploadsEnabledFromEnv,
  type ClientLogUploadRequest,
  type Session,
} from "../types.js";
import { ts } from "../log-utils.js";
import { resolveSdkSessionCwd } from "../sdk-backend.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const LOCAL_SESSION_META_READ_BYTES = 16_384;
const MAX_SESSION_FILE_BYTES = 10 * 1024 * 1024;

export function createSessionRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  function handleListWorkspaceSessions(workspaceId: string, res: ServerResponse): void {
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const sessions = ctx.storage
      .listSessions()
      .filter((s) => s.workspaceId === workspaceId)
      .map((s) => ctx.ensureSessionContextWindow(s));

    helpers.json(res, { sessions, workspace });
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
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
    }>(req);

    // ── Local session import: validate path confinement + CWD alignment ──
    if (body.piSessionFile) {
      const validation = validateLocalSessionPath(body.piSessionFile);
      if ("error" in validation) {
        helpers.error(res, 400, `Invalid session file: ${validation.error}`);
        return;
      }

      // Read CWD from the JSONL header for alignment check
      const headerCwd = await readSessionCwd(validation.path);
      if (!headerCwd) {
        helpers.error(res, 400, "Cannot read session CWD from file");
        return;
      }

      if (!workspace.hostMount) {
        helpers.error(res, 400, "Workspace has no hostMount configured");
        return;
      }

      if (!validateCwdAlignment(headerCwd, workspace.hostMount)) {
        helpers.error(
          res,
          400,
          `Session CWD (${headerCwd}) is not within workspace path (${workspace.hostMount})`,
        );
        return;
      }

      // Extract name and first message from the local session JSONL
      const localMeta = await readLocalSessionMeta(validation.path);
      let sessionName = body.name;
      if (!sessionName) {
        sessionName = localMeta?.name || localMeta?.firstMessage?.slice(0, 80);
      }

      const model = body.model || workspace.lastUsedModel || workspace.defaultModel;
      const session = ctx.storage.createSession(sessionName, model);

      session.workspaceId = workspace.id;
      session.workspaceName = workspace.name;
      if (localMeta?.firstMessage) {
        session.firstMessage = localMeta.firstMessage.slice(0, 200);
      }
      session.piSessionFile = validation.path;
      session.piSessionFiles = [validation.path];
      ctx.storage.saveSession(session);
      invalidateLocalSessionsCache();

      const hydrated = ctx.ensureSessionContextWindow(session);
      helpers.json(res, { session: hydrated }, 201);
      return;
    }

    // ── Standard new session ──
    const model = body.model || workspace.lastUsedModel || workspace.defaultModel;
    const session = ctx.storage.createSession(body.name, model);

    session.workspaceId = workspace.id;
    session.workspaceName = workspace.name;
    if (body.parentSessionId) {
      session.parentSessionId = body.parentSessionId;
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
          images: body.images,
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

  /** Read the CWD from a pi session JSONL header (first line). */
  async function readSessionCwd(filePath: string): Promise<string | null> {
    try {
      const content = await readFile(filePath, "utf8");
      const firstLine = content.split("\n")[0];
      if (!firstLine) return null;
      const header = JSON.parse(firstLine);
      return typeof header.cwd === "string" ? header.cwd : null;
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
      console.error(`${ts()} [resume] Failed to resume session ${sessionId}:`, err);
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

    const forkSession = ctx.storage.createSession(
      forkName,
      latestSource.model || workspace.defaultModel,
    );

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
      console.error(`${ts()} [fork] Failed to fork session ${sourceSessionId}:`, err);
      helpers.error(res, 500, message);
      return;
    }

    const created = ctx.storage.getSession(forkSession.id) || forkSession;
    helpers.json(res, { session: ctx.ensureSessionContextWindow(created) }, 201);
  }

  async function handleStopSession(sessionId: string, res: ServerResponse): Promise<void> {
    const session = ctx.storage.getSession(sessionId);
    if (!session) {
      helpers.error(res, 404, "Session not found");
      return;
    }

    const hydratedSession = ctx.ensureSessionContextWindow(session);

    if (ctx.sessions.isActive(sessionId)) {
      await ctx.sessions.stopSession(sessionId);
    } else {
      hydratedSession.status = "stopped";
      hydratedSession.lastActivity = Date.now();
      ctx.storage.saveSession(hydratedSession);
    }

    const updatedSession = ctx.storage.getSession(sessionId);
    const hydratedUpdated = updatedSession
      ? ctx.ensureSessionContextWindow(updatedSession)
      : updatedSession;
    helpers.json(res, { ok: true, session: hydratedUpdated });
  }

  async function handleUploadClientLogs(
    sessionId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    if (!telemetryUploadsEnabledFromEnv()) {
      helpers.error(res, 403, "telemetry uploads disabled by OPPI_TELEMETRY_MODE");
      return;
    }

    const session = ctx.storage.getSession(sessionId);
    if (!session) {
      helpers.error(res, 404, "Session not found");
      return;
    }

    const body = await helpers.parseBody<ClientLogUploadRequest>(req);
    const rawEntries = Array.isArray(body.entries) ? body.entries : [];
    if (rawEntries.length === 0) {
      helpers.error(res, 400, "entries array required");
      return;
    }

    const receivedAt = Date.now();
    const maxEntries = 1_000;
    const maxMessageChars = 4_000;
    const maxMetadataValueChars = 512;

    const entries = rawEntries
      .slice(-maxEntries)
      .map((entry) => {
        const metadata: Record<string, string> = {};
        if (entry.metadata) {
          for (const [key, value] of Object.entries(entry.metadata)) {
            if (typeof value !== "string") continue;
            metadata[key.slice(0, 64)] = value.slice(0, maxMetadataValueChars);
          }
        }

        const level =
          entry.level === "debug" ||
          entry.level === "info" ||
          entry.level === "warning" ||
          entry.level === "error"
            ? entry.level
            : "info";

        return {
          timestamp:
            typeof entry.timestamp === "number" && Number.isFinite(entry.timestamp)
              ? Math.trunc(entry.timestamp)
              : receivedAt,
          level,
          category:
            typeof entry.category === "string" && entry.category.trim().length > 0
              ? entry.category.trim().slice(0, 64)
              : "unknown",
          message: typeof entry.message === "string" ? entry.message.slice(0, maxMessageChars) : "",
          metadata,
        };
      })
      .filter((entry) => entry.message.length > 0);

    if (entries.length === 0) {
      helpers.error(res, 400, "No valid log entries");
      return;
    }

    const logsDir = join(ctx.storage.getDataDir(), "client-logs");
    if (!(await pathExists(logsDir))) {
      await mkdir(logsDir, { recursive: true, mode: 0o700 });
    }

    const logPath = join(logsDir, `${sessionId}.jsonl`);
    const envelope = {
      receivedAt,
      generatedAt:
        typeof body.generatedAt === "number" && Number.isFinite(body.generatedAt)
          ? Math.trunc(body.generatedAt)
          : receivedAt,
      trigger:
        typeof body.trigger === "string" && body.trigger.trim().length > 0
          ? body.trigger.trim().slice(0, 64)
          : "manual",
      appVersion: typeof body.appVersion === "string" ? body.appVersion.slice(0, 64) : undefined,
      buildNumber: typeof body.buildNumber === "string" ? body.buildNumber.slice(0, 64) : undefined,
      osVersion: typeof body.osVersion === "string" ? body.osVersion.slice(0, 128) : undefined,
      deviceModel: typeof body.deviceModel === "string" ? body.deviceModel.slice(0, 64) : undefined,
      sessionId,
      workspaceId: session.workspaceId,
      entries,
    };

    await appendFile(logPath, `${JSON.stringify(envelope)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });

    console.log("[diagnostics] client logs uploaded", {
      user: ctx.storage.getOwnerName(),
      sessionId,
      entries: entries.length,
    });
    helpers.json(res, { ok: true, accepted: entries.length });
  }

  // ─── Tool Output by ID ───

  async function handleGetFullToolOutput(
    sessionId: string,
    toolCallId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const session = ctx.storage.getSession(sessionId);
    if (!session) {
      helpers.error(res, 404, "Session not found");
      return;
    }

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

  async function handleGetToolOutput(
    sessionId: string,
    toolCallId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const session = ctx.storage.getSession(sessionId);
    if (!session) {
      helpers.error(res, 404, "Session not found");
      return;
    }

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

  // ─── Session File Access ───

  async function handleGetSessionFile(
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const session = ctx.storage.getSession(sessionId);
    if (!session) {
      helpers.error(res, 404, "Session not found");
      return;
    }

    const reqPath = url.searchParams.get("path");
    if (!reqPath) {
      helpers.error(res, 400, "path parameter required");
      return;
    }

    const workRoot = await resolveWorkRoot(session);
    if (!workRoot) {
      helpers.error(res, 404, "No workspace root for session");
      return;
    }

    const target = resolve(workRoot, reqPath);
    let resolved: string;
    try {
      resolved = await realpath(target);
    } catch {
      helpers.error(res, 404, "File not found");
      return;
    }

    const realWorkRoot = await realpath(workRoot);
    if (!isPathWithinRoot(resolved, realWorkRoot)) {
      helpers.error(res, 403, "Path outside workspace");
      return;
    }

    let fileStat: Awaited<ReturnType<typeof stat>>;
    try {
      fileStat = await stat(resolved);
    } catch {
      helpers.error(res, 404, "File not found");
      return;
    }

    if (!fileStat.isFile()) {
      helpers.error(res, 400, "Not a file");
      return;
    }

    if (fileStat.size > MAX_SESSION_FILE_BYTES) {
      helpers.error(res, 413, "File too large (max 10MB)");
      return;
    }

    const mime = guessMime(resolved);
    res.writeHead(200, {
      "Content-Type": mime,
      "Content-Length": fileStat.size,
      "Cache-Control": "no-cache",
    });
    createReadStream(resolved).pipe(res);
  }

  async function handleGetSessionOverallDiff(
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const session = ctx.storage.getSession(sessionId);
    if (!session) {
      helpers.error(res, 404, "Session not found");
      return;
    }

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
  ): ReturnType<typeof readSessionTrace> {
    const baseDir = traceBaseDir();
    let trace = readSessionTrace(baseDir, session.id, session.workspaceId, {
      view: traceView,
    });

    if ((!trace || trace.length === 0) && session.piSessionFiles?.length) {
      trace = readSessionTraceFromFiles(session.piSessionFiles, { view: traceView });
    }
    if ((!trace || trace.length === 0) && session.piSessionFile) {
      trace = readSessionTraceFromFile(session.piSessionFile, { view: traceView });
    }
    if ((!trace || trace.length === 0) && session.piSessionId) {
      trace = readSessionTraceByUuid(baseDir, session.piSessionId, session.workspaceId, {
        view: traceView,
      });
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

  function handleGetSessionEvents(sessionId: string, url: URL, res: ServerResponse): void {
    const session = ctx.storage.getSession(sessionId);
    if (!session) {
      helpers.error(res, 404, "Session not found");
      return;
    }

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

  async function handleGetSession(sessionId: string, url: URL, res: ServerResponse): Promise<void> {
    const session = ctx.storage.getSession(sessionId);
    if (!session) {
      helpers.error(res, 404, "Session not found");
      return;
    }

    const traceView = resolveTraceView(url);
    const hydratedSession = ctx.ensureSessionContextWindow(session);
    const baseDir = traceBaseDir();

    let trace = loadSessionTrace(hydratedSession, traceView);

    if (!trace || trace.length === 0) {
      const live = await ctx.sessions.refreshSessionState(sessionId);
      if (live?.sessionFile) {
        trace = readSessionTraceFromFile(live.sessionFile, { view: traceView });
      }
      if ((!trace || trace.length === 0) && live?.sessionId) {
        trace = readSessionTraceByUuid(baseDir, live.sessionId, hydratedSession.workspaceId, {
          view: traceView,
        });
      }

      const refreshed = ctx.storage.getSession(sessionId);
      if (refreshed && (!trace || trace.length === 0)) {
        ctx.ensureSessionContextWindow(refreshed);
        trace = loadSessionTrace(refreshed, traceView);
      }
    }

    const latestSession = ctx.storage.getSession(sessionId) || hydratedSession;
    const hydratedLatest = ctx.ensureSessionContextWindow(latestSession);
    helpers.json(res, { session: hydratedLatest, trace: trace || [] });
  }

  async function handleDeleteSession(sessionId: string, res: ServerResponse): Promise<void> {
    const session = ctx.storage.getSession(sessionId);
    if (!session) {
      helpers.error(res, 404, "Session not found");
      return;
    }

    await ctx.sessions.stopSession(sessionId);
    ctx.storage.deleteSession(sessionId);

    // Notify connected clients so they can remove stale session entries.
    ctx.streamMux.recordUserStreamEvent(sessionId, {
      type: "session_deleted",
      sessionId,
    });

    helpers.json(res, { ok: true });
  }

  return async ({ method, path, url, req, res }) => {
    // ── Workspace-scoped session routes (v2 API) ──

    const wsSessionsMatch = path.match(/^\/workspaces\/([^/]+)\/sessions$/);
    if (wsSessionsMatch) {
      if (method === "GET") {
        handleListWorkspaceSessions(wsSessionsMatch[1], res);
        return true;
      }
      if (method === "POST") {
        await handleCreateWorkspaceSession(wsSessionsMatch[1], req, res);
        return true;
      }
    }

    const wsSessionStopMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stop$/);
    if (wsSessionStopMatch && method === "POST") {
      await handleStopSession(wsSessionStopMatch[2], res);
      return true;
    }

    const wsSessionClientLogsMatch = path.match(
      /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/client-logs$/,
    );
    if (wsSessionClientLogsMatch && method === "POST") {
      await handleUploadClientLogs(wsSessionClientLogsMatch[2], req, res);
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

    const wsSessionToolOutputFullMatch = path.match(
      /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/tool-output\/([^/]+)\/full$/,
    );
    if (wsSessionToolOutputFullMatch && method === "GET") {
      await handleGetFullToolOutput(
        wsSessionToolOutputFullMatch[2],
        wsSessionToolOutputFullMatch[3],
        req,
        res,
      );
      return true;
    }

    const wsSessionToolOutputMatch = path.match(
      /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/tool-output\/([^/]+)$/,
    );
    if (wsSessionToolOutputMatch && method === "GET") {
      await handleGetToolOutput(wsSessionToolOutputMatch[2], wsSessionToolOutputMatch[3], req, res);
      return true;
    }

    const wsSessionFilesMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/files$/);
    if (wsSessionFilesMatch && method === "GET") {
      await handleGetSessionFile(wsSessionFilesMatch[2], url, res);
      return true;
    }

    const wsSessionOverallDiffMatch = path.match(
      /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/overall-diff$/,
    );
    if (wsSessionOverallDiffMatch && method === "GET") {
      await handleGetSessionOverallDiff(wsSessionOverallDiffMatch[2], url, res);
      return true;
    }

    const wsSessionEventsMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/events$/);
    if (wsSessionEventsMatch && method === "GET") {
      handleGetSessionEvents(wsSessionEventsMatch[2], url, res);
      return true;
    }

    const wsSessionMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)$/);
    if (wsSessionMatch) {
      if (method === "GET") {
        await handleGetSession(wsSessionMatch[2], url, res);
        return true;
      }
      if (method === "DELETE") {
        await handleDeleteSession(wsSessionMatch[2], res);
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

/** Minimal MIME type guesser for file serving. */
function guessMime(filePath: string): string {
  const ext = extname(filePath).toLowerCase();
  const mimeMap: Record<string, string> = {
    ".html": "text/html",
    ".htm": "text/html",
    ".css": "text/css",
    ".js": "text/javascript",
    ".mjs": "text/javascript",
    ".ts": "text/typescript",
    ".json": "application/json",
    ".md": "text/markdown",
    ".txt": "text/plain",
    ".csv": "text/csv",
    ".xml": "application/xml",
    ".yaml": "text/yaml",
    ".yml": "text/yaml",
    ".toml": "text/plain",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".pdf": "application/pdf",
    ".zip": "application/zip",
    ".gz": "application/gzip",
    ".tar": "application/x-tar",
    ".wasm": "application/wasm",
    ".py": "text/x-python",
    ".rs": "text/x-rust",
    ".go": "text/x-go",
    ".swift": "text/x-swift",
    ".sh": "text/x-shellscript",
    ".log": "text/plain",
  };
  return mimeMap[ext] || "application/octet-stream";
}
