import { homedir } from "node:os";
import { extname, isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { access, readFile, realpath, stat } from "node:fs/promises";

import {
  getContentType,
  isBrowseMediaContentType,
  isStreamingMediaContentType,
  MAX_BROWSE_IMAGE_FILE_SIZE,
  MAX_BROWSE_TEXT_FILE_SIZE,
} from "./file-serving-policy.js";
import { isPathWithinRoot } from "./git-utils.js";
import {
  collectFileMutations,
  computeDiffLines,
  computeLineDiffStatsFromLines,
  reconstructBaselineFromCurrent,
} from "./diff-core.js";
import { MobileRendererRegistry } from "./mobile-renderer.js";
import type { SessionRuntimes } from "./runtime-router.js";
import { resolveSdkSessionCwd } from "./sdk-backend.js";
import type { Storage } from "./storage.js";
import {
  collectSessionTraceJsonlPaths,
  findToolOutput,
  readSessionTrace,
  readSessionTraceByUuid,
  readSessionTraceFromFile,
  readSessionTraceFromFiles,
  type TraceEvent,
  type TraceViewMode,
} from "./trace.js";
import {
  readSessionTracePageFromFiles,
  type TracePageMetadata,
  type TracePageMetrics,
} from "./trace-paging.js";
import {
  readSessionTraceOutlineFromFiles,
  type TraceOutlineMetrics,
  type TraceOutlineSnapshot,
} from "./trace-outline.js";
import type { Session, Workspace, WorkspaceReviewDiffResponse } from "./types.js";
import { buildDiffHunks } from "./workspace-review-diff.js";

const MAX_SESSION_FILE_BYTES = 10 * 1024 * 1024;

export type SessionTraceViewMode = TraceViewMode;

export interface SessionTraceResult {
  session: Session;
  trace: TraceEvent[];
}

export interface SessionTracePageResult {
  session: Session;
  trace: TraceEvent[];
  page: TracePageMetadata;
  metrics: TracePageMetrics;
}

export interface SessionTraceOutlineResult {
  session: Session;
  outline: TraceOutlineSnapshot;
  metrics: TraceOutlineMetrics;
}

export interface SessionToolOutputResult {
  toolCallId: string;
  output: string;
  isError: boolean;
}

export interface SessionFullToolOutputResult {
  toolCallId: string;
  output: string;
}

export type SessionOverallDiffResult =
  | { kind: "ok"; diff: WorkspaceReviewDiffResponse }
  | { kind: "trace-not-found" }
  | { kind: "mutations-not-found" }
  | { kind: "workspace-root-not-found" }
  | { kind: "current-file-not-found" }
  | { kind: "current-file-outside-workspace" }
  | { kind: "current-file-not-file" }
  | { kind: "current-file-too-large"; maxSizeMegabytes: number }
  | { kind: "current-file-unreadable" };

type CurrentFileTextResult =
  | { kind: "ok"; text: string }
  | Exclude<SessionOverallDiffResult, { kind: "ok" | "trace-not-found" | "mutations-not-found" }>;

export interface SessionChangesResult {
  workspaceId: string;
  sessionId: string;
  files: Array<{ path: string }>;
  changedFileCount: number;
  changedFilesOverflow: number;
}

export type SessionRawFileResult =
  | { kind: "ok"; filePath: string; contentType: string; size: number }
  | { kind: "path-required" }
  | { kind: "file-not-found" }
  | { kind: "workspace-root-not-found" }
  | { kind: "path-outside-workspace" }
  | { kind: "not-file" }
  | { kind: "file-too-large"; maxSizeMegabytes: number };

export interface SessionTraceServiceDeps {
  storage: Pick<Storage, "getDataDir" | "getSession" | "getWorkspace">;
  sessionRuntimes: Pick<SessionRuntimes, "getToolFullOutputPath" | "refreshSessionState">;
  ensureSessionContextWindow: (session: Session) => Session;
  mobileRenderers?: Pick<MobileRendererRegistry, "renderCall" | "renderResult">;
}

/**
 * Application service for session trace and tool-output read policy.
 *
 * Routes keep ownership validation and HTTP status mapping; this service owns
 * trace source precedence across stored Oppi traces, imported Pi JSONL files,
 * and live runtime refresh metadata.
 */
export class SessionTraceService {
  private readonly mobileRenderers: Pick<MobileRendererRegistry, "renderCall" | "renderResult">;

  constructor(private readonly deps: SessionTraceServiceDeps) {
    this.mobileRenderers = deps.mobileRenderers ?? new MobileRendererRegistry();
  }

  async getSessionWithTrace(params: {
    session: Session;
    traceView?: SessionTraceViewMode;
    includePresentationSegments?: boolean;
  }): Promise<SessionTraceResult> {
    const traceView = params.traceView ?? "context";
    const live = await this.deps.sessionRuntimes.refreshSessionState(params.session.id);
    const liveLeafId = typeof live?.leafId === "string" ? live.leafId : undefined;
    const refreshedSession = this.deps.storage.getSession(params.session.id) || params.session;
    const hydratedSession = this.deps.ensureSessionContextWindow(refreshedSession);
    const baseDir = this.traceBaseDir();

    let trace = this.loadSessionTrace(hydratedSession, traceView, liveLeafId);

    if (!trace || trace.length === 0) {
      const traceOptions = {
        view: traceView,
        attachmentDataDir: baseDir,
        attachmentSessionId: params.session.id,
        ...(liveLeafId !== undefined ? { leafId: liveLeafId } : {}),
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

      const refreshed = this.deps.storage.getSession(params.session.id);
      if (refreshed && (!trace || trace.length === 0)) {
        this.deps.ensureSessionContextWindow(refreshed);
        trace = this.loadSessionTrace(refreshed, traceView, liveLeafId);
      }
    }

    const latestSession = this.deps.storage.getSession(params.session.id) || hydratedSession;
    return {
      session: this.deps.ensureSessionContextWindow(latestSession),
      trace: params.includePresentationSegments
        ? this.withMobileRenderSegments(trace || [])
        : trace || [],
    };
  }

  async getSessionTracePage(params: {
    session: Session;
    cursor?: string;
    aroundEntryId?: string;
    targetEvents?: number;
    previewBytes?: number;
    includePresentationSegments?: boolean;
  }): Promise<SessionTracePageResult | null> {
    const live = await this.deps.sessionRuntimes.refreshSessionState(params.session.id);
    const refreshedSession = this.deps.storage.getSession(params.session.id) || params.session;
    const hydratedSession = this.deps.ensureSessionContextWindow(refreshedSession);
    const jsonlPaths = await this.collectTracePageJsonlPaths(
      hydratedSession,
      typeof live?.sessionFile === "string" ? live.sessionFile : undefined,
    );
    if (jsonlPaths.length === 0) {
      const latestSession = this.deps.storage.getSession(params.session.id) || hydratedSession;
      const previewBytes = Math.max(0, params.previewBytes ?? 4096);
      return {
        session: this.deps.ensureSessionContextWindow(latestSession),
        trace: [],
        page: {
          hasOlder: false,
          olderCursor: null,
          traceVersion: "",
          previewBytes,
          staleCursor: typeof live?.leafId === "string",
        },
        metrics: {
          rawEntryCount: 0,
          traceEventCount: 0,
          selectedRawEntryCount: 0,
          jsonlBytes: 0,
          scannedBytes: 0,
          readMs: 0,
          parseMs: 0,
          selectMs: 0,
          formatMs: 0,
          previewMs: 0,
        },
      };
    }

    const result = readSessionTracePageFromFiles(jsonlPaths, {
      cursor: params.cursor,
      aroundEntryId: params.aroundEntryId,
      targetEvents: params.targetEvents,
      previewBytes: params.previewBytes,
      attachmentDataDir: this.traceBaseDir(),
      attachmentSessionId: params.session.id,
      ...(!params.cursor && !params.aroundEntryId && live?.leafId !== undefined
        ? { leafId: live.leafId }
        : {}),
    });
    const latestSession = this.deps.storage.getSession(params.session.id) || hydratedSession;
    return {
      session: this.deps.ensureSessionContextWindow(latestSession),
      trace: params.includePresentationSegments
        ? this.withMobileRenderSegments(result.trace)
        : result.trace,
      page: result.page,
      metrics: result.metrics,
    };
  }

  async getSessionTraceOutline(params: { session: Session }): Promise<SessionTraceOutlineResult> {
    const live = await this.deps.sessionRuntimes.refreshSessionState(params.session.id);
    const refreshedSession = this.deps.storage.getSession(params.session.id) || params.session;
    const hydratedSession = this.deps.ensureSessionContextWindow(refreshedSession);
    const jsonlPaths = await this.collectTracePageJsonlPaths(
      hydratedSession,
      typeof live?.sessionFile === "string" ? live.sessionFile : undefined,
    );
    const result = await readSessionTraceOutlineFromFiles(jsonlPaths);
    const latestSession = this.deps.storage.getSession(params.session.id) || hydratedSession;
    return {
      session: this.deps.ensureSessionContextWindow(latestSession),
      outline: result.outline,
      metrics: result.metrics,
    };
  }

  loadSessionTrace(
    session: Session,
    traceView: SessionTraceViewMode = "context",
    leafId?: string | null,
  ): TraceEvent[] | null {
    const baseDir = this.traceBaseDir();
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
    if ((!trace || trace.length === 0) && session.id) {
      trace = readSessionTraceByUuid(
        baseDir,
        session.id,
        session.workspaceId,
        traceOptions,
      );
    }

    return trace;
  }

  async getToolOutput(
    session: Session,
    toolCallId: string,
  ): Promise<SessionToolOutputResult | null> {
    const jsonlPaths = await this.collectExistingSessionJsonlPaths(session);

    for (const jsonlPath of jsonlPaths) {
      const output = findToolOutput(jsonlPath, toolCallId);
      if (output !== null) {
        return {
          toolCallId,
          output: output.text,
          isError: output.isError,
        };
      }
    }

    return null;
  }

  async getFullToolOutput(
    sessionId: string,
    toolCallId: string,
  ): Promise<SessionFullToolOutputResult | null> {
    const fullOutputPath = this.deps.sessionRuntimes.getToolFullOutputPath(sessionId, toolCallId);
    if (!fullOutputPath) {
      return null;
    }

    try {
      return {
        toolCallId,
        output: await readFile(fullOutputPath, "utf8"),
      };
    } catch {
      return null;
    }
  }

  async getSessionOverallDiff(params: {
    session: Session;
    path: string;
  }): Promise<SessionOverallDiffResult> {
    const trace = this.loadSessionTrace(params.session);
    if (!trace || trace.length === 0) {
      return { kind: "trace-not-found" };
    }

    const mutations = collectFileMutations(trace, params.path);
    if (mutations.length === 0) {
      return { kind: "mutations-not-found" };
    }

    const currentFile = await this.readCurrentFileText(params.session, params.path);
    if (currentFile.kind !== "ok") {
      return currentFile;
    }

    const currentText = currentFile.text;
    const baselineText = reconstructBaselineFromCurrent(currentText, mutations);
    const flatLines = computeDiffLines(baselineText, currentText);
    const hunks = buildDiffHunks(flatLines);
    const stats = computeLineDiffStatsFromLines(flatLines);

    return {
      kind: "ok",
      diff: {
        workspaceId: params.session.workspaceId ?? "",
        path: params.path,
        baselineText,
        currentText,
        addedLines: stats.added,
        removedLines: stats.removed,
        hunks,
        revisionCount: mutations.length,
        cacheKey: `${params.session.id}:${params.path}:${mutations[mutations.length - 1]?.id ?? "none"}`,
      },
    };
  }

  listSessionChanges(session: Session): SessionChangesResult {
    const changeStats = session.changeStats;
    return {
      workspaceId: session.workspaceId ?? "",
      sessionId: session.id,
      files: (changeStats?.changedFiles ?? []).map((path) => ({ path })),
      changedFileCount: changeStats?.filesChanged ?? 0,
      changedFilesOverflow: changeStats?.changedFilesOverflow ?? 0,
    };
  }

  async getSessionRawFile(params: {
    workspace: Workspace;
    session: Session;
    path: string;
  }): Promise<SessionRawFileResult> {
    const reqPath = params.path;
    if (!reqPath) {
      return { kind: "path-required" };
    }

    const workspaceRoot = resolveSdkSessionCwd(params.workspace, params.session, {
      dataDir: this.deps.storage.getDataDir(),
    });
    let realWorkspaceRoot: string;
    try {
      realWorkspaceRoot = await realpath(workspaceRoot);
    } catch {
      return { kind: "workspace-root-not-found" };
    }

    const requestedPath = resolveSessionRawPath(reqPath, realWorkspaceRoot);
    if (!requestedPath) {
      return { kind: "path-outside-workspace" };
    }

    let resolvedPath: string;
    try {
      resolvedPath = await realpath(requestedPath);
    } catch {
      return { kind: "file-not-found" };
    }

    if (
      !isPathWithinRoot(resolvedPath, realWorkspaceRoot) &&
      !this.sessionReportsPath(params.session, reqPath)
    ) {
      return { kind: "path-outside-workspace" };
    }

    let fileStat: Awaited<ReturnType<typeof stat>>;
    try {
      fileStat = await stat(resolvedPath);
    } catch {
      return { kind: "file-not-found" };
    }

    if (!fileStat.isFile()) {
      return { kind: "not-file" };
    }

    const ext = extname(resolvedPath).toLowerCase();
    const filename = resolvedPath.split("/").pop() ?? resolvedPath;
    const contentType = getContentType(ext, filename);
    if (!isStreamingMediaContentType(contentType)) {
      const isMedia = isBrowseMediaContentType(contentType);
      const maxSize = isMedia ? MAX_BROWSE_IMAGE_FILE_SIZE : MAX_BROWSE_TEXT_FILE_SIZE;
      if (fileStat.size > maxSize) {
        return {
          kind: "file-too-large",
          maxSizeMegabytes: Math.round(maxSize / (1024 * 1024)),
        };
      }
    }

    return {
      kind: "ok",
      filePath: resolvedPath,
      contentType,
      size: fileStat.size,
    };
  }

  private sessionReportsPath(session: Session, requestedPath: string): boolean {
    const changedFiles = session.changeStats?.changedFiles ?? [];
    const sessionCreatedFiles = session.changeStats?._sessionCreatedFiles ?? [];
    if (changedFiles.includes(requestedPath) || sessionCreatedFiles.includes(requestedPath)) {
      return true;
    }

    const trace = this.loadSessionTrace(session, "full") ?? [];
    return trace.some(
      (event) => event.type === "toolCall" && containsExactString(event.args, requestedPath),
    );
  }

  private async readCurrentFileText(
    session: Session,
    reqPath: string,
  ): Promise<CurrentFileTextResult> {
    const workRoot = await this.resolveWorkRoot(session);
    if (!workRoot) return { kind: "workspace-root-not-found" };

    let realWorkRoot: string;
    try {
      realWorkRoot = await realpath(workRoot);
    } catch {
      return { kind: "workspace-root-not-found" };
    }

    const target = resolve(workRoot, reqPath);
    let resolved: string;
    try {
      resolved = await realpath(target);
    } catch (error: unknown) {
      return isPathMissingError(error)
        ? { kind: "current-file-not-found" }
        : { kind: "current-file-unreadable" };
    }

    if (!isPathWithinRoot(resolved, realWorkRoot)) {
      return { kind: "current-file-outside-workspace" };
    }

    let fileStat: Awaited<ReturnType<typeof stat>>;
    try {
      fileStat = await stat(resolved);
    } catch {
      return { kind: "current-file-unreadable" };
    }

    if (!fileStat.isFile()) {
      return { kind: "current-file-not-file" };
    }

    if (fileStat.size > MAX_SESSION_FILE_BYTES) {
      return {
        kind: "current-file-too-large",
        maxSizeMegabytes: Math.round(MAX_SESSION_FILE_BYTES / (1024 * 1024)),
      };
    }

    try {
      return { kind: "ok", text: await readFile(resolved, "utf8") };
    } catch {
      return { kind: "current-file-unreadable" };
    }
  }

  private async resolveWorkRoot(session: Session): Promise<string | null> {
    const workspace = session.workspaceId
      ? this.deps.storage.getWorkspace(session.workspaceId)
      : undefined;

    if (workspace?.hostMount) {
      const resolved = resolveSdkSessionCwd(workspace, session, {
        dataDir: this.deps.storage.getDataDir(),
      });
      return (await pathExists(resolved)) ? resolved : null;
    }
    return homedir();
  }

  private withMobileRenderSegments(trace: TraceEvent[]): TraceEvent[] {
    const toolNames = new Map<string, string>();
    return trace.map((event) => {
      if (event.type === "toolCall") {
        const tool = event.tool ?? "unknown";
        toolNames.set(event.id, tool);
        const callSegments = this.mobileRenderers.renderCall(tool, event.args ?? {});
        return callSegments ? { ...event, callSegments } : event;
      }
      if (event.type === "toolResult") {
        const tool = event.toolName ?? toolNames.get(event.toolCallId ?? "");
        if (!tool) return event;
        const resultSegments = this.mobileRenderers.renderResult(
          tool,
          event.details,
          event.isError === true,
        );
        return resultSegments ? { ...event, resultSegments } : event;
      }
      return event;
    });
  }

  private traceBaseDir(): string {
    return this.deps.storage.getDataDir?.() ?? process.cwd();
  }

  private async collectTracePageJsonlPaths(
    session: Session,
    liveSessionFile: string | undefined,
  ): Promise<string[]> {
    const baseDir = this.traceBaseDir();
    const canonical = await existingPaths(
      collectSessionTraceJsonlPaths(baseDir, session.id, session.workspaceId),
    );
    if (canonical.length > 0) return canonical;

    const explicit = await this.collectExistingSessionJsonlPaths(session);
    if (explicit.length > 0) return explicit;

    return liveSessionFile ? existingPaths([liveSessionFile]) : [];
  }

  private async collectExistingSessionJsonlPaths(session: Session): Promise<string[]> {
    const candidates = [...(session.piSessionFiles ?? [])];
    if (session.piSessionFile) {
      candidates.push(session.piSessionFile);
    }

    return existingPaths(candidates);
  }
}

function resolveSessionRawPath(requestedPath: string, workspaceRoot: string): string | null {
  if (requestedPath.toLowerCase().startsWith("file:")) {
    try {
      const url = new URL(requestedPath);
      return url.protocol === "file:" ? fileURLToPath(url) : null;
    } catch {
      return null;
    }
  }

  if (requestedPath === "~" || requestedPath.startsWith("~/")) {
    return resolve(requestedPath.replace(/^~(?=\/|$)/, homedir()));
  }

  return isAbsolute(requestedPath) ? resolve(requestedPath) : resolve(workspaceRoot, requestedPath);
}

function containsExactString(value: unknown, expected: string): boolean {
  if (typeof value === "string") {
    return value === expected;
  }
  if (Array.isArray(value)) {
    return value.some((item) => containsExactString(item, expected));
  }
  if (typeof value === "object" && value !== null) {
    return Object.values(value).some((item) => containsExactString(item, expected));
  }
  return false;
}

async function existingPaths(candidates: string[]): Promise<string[]> {
  const uniquePaths = Array.from(new Set(candidates));
  const existing = await Promise.all(
    uniquePaths.map(async (candidate) => ({
      candidate,
      exists: await pathExists(candidate),
    })),
  );

  return existing.filter((entry) => entry.exists).map((entry) => entry.candidate);
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

function isPathMissingError(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error.code === "ENOENT" || error.code === "ENOTDIR")
  );
}
