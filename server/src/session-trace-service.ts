import { homedir } from "node:os";
import { resolve } from "node:path";
import { access, readFile, realpath, stat } from "node:fs/promises";

import { openVerifiedFile, resolveCurrentFilePath, statServableFile } from "./current-file.js";
import { isPathWithinRoot } from "./git-utils.js";
import {
  collectFileMutations,
  computeDiffLines,
  computeLineDiffStatsFromLines,
  reconstructBaselineFromCurrent,
} from "./diff-core.js";
import { type MobileRendererRegistry, resolveToolDisplay } from "./mobile-renderer.js";
import type { SessionRuntimes } from "./runtime-router.js";
import { resolveSdkSessionCwdAsync } from "./sdk-backend.js";
import { WorkspaceWorktreeError } from "./worktrees.js";
import type { Storage } from "./storage.js";
import {
  collectSessionTraceJsonlPaths,
  findToolOutput,
  readSessionTrace,
  readSessionTraceByUuid,
  readSessionTraceFromFile,
  readSessionTraceFromFiles,
  type LiveEntryRendererSet,
  type TraceEvent,
  type TraceReadOptions,
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
import { sanitizeToolResultDetails } from "./visual-schema.js";

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
  sessionRuntimes: Pick<
    SessionRuntimes,
    "getToolFullOutputPath" | "getToolPartialOutput" | "refreshSessionState"
  > & {
    getEntryRenderers?: SessionRuntimes["getEntryRenderers"];
    getServerDurableTrace?: SessionRuntimes["getServerDurableTrace"];
    getServerDurableTracePage?: SessionRuntimes["getServerDurableTracePage"];
    getServerDurableTraceOutline?: SessionRuntimes["getServerDurableTraceOutline"];
  };
  ensureSessionContextWindow: (session: Session) => Session;
  getMcpServerNames?: (session: Session) => readonly string[];
  mobileRenderers: MobileRendererRegistry;
}

/**
 * Application service for session trace and tool-output read policy.
 *
 * Routes keep ownership validation and HTTP status mapping; this service owns
 * trace source precedence across stored Oppi traces, imported Pi JSONL files,
 * and live runtime refresh metadata.
 */
export class SessionTraceService {
  private readonly mobileRenderers: MobileRendererRegistry;

  constructor(private readonly deps: SessionTraceServiceDeps) {
    this.mobileRenderers = deps.mobileRenderers;
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
    const entryRenderers = this.liveEntryRenderers(params.session.id);

    let trace =
      (await this.deps.sessionRuntimes.getServerDurableTrace?.(params.session.id, traceView)) ??
      this.loadSessionTrace(hydratedSession, traceView, liveLeafId, entryRenderers);

    if (!trace || trace.length === 0) {
      const traceOptions = this.traceReadOptions({
        sessionId: params.session.id,
        view: traceView,
        leafId: liveLeafId,
        entryRenderers,
      });

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
        trace = this.loadSessionTrace(refreshed, traceView, liveLeafId, entryRenderers);
      }
    }

    const latestSession = this.deps.storage.getSession(params.session.id) || hydratedSession;
    return {
      session: this.deps.ensureSessionContextWindow(latestSession),
      trace: this.withMobileRenderSegments(
        trace || [],
        params.includePresentationSegments === true,
        this.deps.getMcpServerNames?.(latestSession) ?? [],
      ),
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
    const durablePage = await this.deps.sessionRuntimes.getServerDurableTracePage?.(
      params.session.id,
      {
        cursor: params.cursor,
        aroundEntryId: params.aroundEntryId,
        targetEvents: params.targetEvents,
        previewBytes: params.previewBytes,
      },
    );
    if (durablePage) {
      const latestSession = this.deps.storage.getSession(params.session.id) || hydratedSession;
      return {
        session: this.deps.ensureSessionContextWindow(latestSession),
        ...durablePage,
        trace: this.withMobileRenderSegments(
          durablePage.trace,
          params.includePresentationSegments === true,
          this.deps.getMcpServerNames?.(latestSession) ?? [],
        ),
      };
    }
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

    const entryRenderers = this.liveEntryRenderers(params.session.id);
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
      ...(entryRenderers ? { entryRenderers } : {}),
    });
    const latestSession = this.deps.storage.getSession(params.session.id) || hydratedSession;
    return {
      session: this.deps.ensureSessionContextWindow(latestSession),
      trace: this.withMobileRenderSegments(
        result.trace,
        params.includePresentationSegments === true,
        this.deps.getMcpServerNames?.(latestSession) ?? [],
      ),
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
    const entryRenderers = this.liveEntryRenderers(params.session.id);
    const result =
      (await this.deps.sessionRuntimes.getServerDurableTraceOutline?.(params.session.id)) ??
      (await readSessionTraceOutlineFromFiles(jsonlPaths, {
        mobileRenderers: this.mobileRenderers,
        ...(entryRenderers ? { entryRenderers } : {}),
      }));
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
    entryRenderers?: LiveEntryRendererSet,
  ): TraceEvent[] | null {
    const baseDir = this.traceBaseDir();
    const traceOptions = this.traceReadOptions({
      sessionId: session.id,
      view: traceView,
      leafId,
      entryRenderers: entryRenderers ?? this.liveEntryRenderers(session.id),
    });
    let trace = readSessionTrace(baseDir, session.id, session.workspaceId, traceOptions);

    if ((!trace || trace.length === 0) && session.piSessionFiles?.length) {
      trace = readSessionTraceFromFiles(session.piSessionFiles, traceOptions);
    }
    if ((!trace || trace.length === 0) && session.piSessionFile) {
      trace = readSessionTraceFromFile(session.piSessionFile, traceOptions);
    }
    if ((!trace || trace.length === 0) && session.id) {
      trace = readSessionTraceByUuid(baseDir, session.id, session.workspaceId, traceOptions);
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
    if (fullOutputPath) {
      try {
        return { toolCallId, output: await readFile(fullOutputPath, "utf8") };
      } catch {
        // Never present Pi's truncated trace text as full when its file is gone.
        return null;
      }
    }
    const partial = this.deps.sessionRuntimes.getToolPartialOutput(sessionId, toolCallId);
    if (partial !== null) return { toolCallId, output: partial };
    const session = this.deps.storage.getSession(sessionId);
    if (!session) return null;
    for (const jsonlPath of await this.collectExistingSessionJsonlPaths(session)) {
      const output = findToolOutput(jsonlPath, toolCallId, { requireComplete: true });
      if (output !== null) return { toolCallId, output: output.text };
    }
    return null;
  }

  async statFullToolOutput(
    sessionId: string,
    toolCallId: string,
  ): Promise<{ path: string; size: number } | null> {
    const fullOutputPath = this.deps.sessionRuntimes.getToolFullOutputPath(sessionId, toolCallId);
    if (!fullOutputPath) {
      return null;
    }

    try {
      const info = await stat(fullOutputPath);
      if (!info.isFile()) return null;
      return { path: fullOutputPath, size: info.size };
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
    if (!params.path) {
      return { kind: "path-required" };
    }

    const workspaceRoot = await this.resolveSdkCwdOrNull(params.workspace, params.session);
    if (!workspaceRoot) return { kind: "workspace-root-not-found" };

    // Host workspaces: pairing/auth is the gate. Sandbox stays confined after realpath.
    const resolved = await resolveCurrentFilePath(
      {
        kind: "workspace",
        workspace: params.workspace,
        root: workspaceRoot,
        dataDir: this.deps.storage.getDataDir(),
      },
      params.path,
    );
    switch (resolved.kind) {
      case "root-not-found":
        return { kind: "workspace-root-not-found" };
      case "outside-sandbox":
        return { kind: "path-outside-workspace" };
      case "not-found":
        return { kind: "file-not-found" };
      case "ok":
        break;
    }

    const servable = await statServableFile(resolved.file.realPath);
    switch (servable.kind) {
      case "ok":
        return { kind: "ok", ...servable.file };
      case "not-file":
        return { kind: "not-file" };
      case "too-large":
        return { kind: "file-too-large", maxSizeMegabytes: servable.maxSizeMegabytes };
      case "missing":
      case "unreadable":
        return { kind: "file-not-found" };
    }
  }

  private async readCurrentFileText(
    session: Session,
    reqPath: string,
  ): Promise<CurrentFileTextResult> {
    const workRoot = await this.resolveWorkRoot(session);
    if (!workRoot) return { kind: "workspace-root-not-found" };

    const workspace = session.workspaceId
      ? this.deps.storage.getWorkspace(session.workspaceId)
      : undefined;
    let resolved: string;
    if (workspace?.runtime === "sandbox") {
      const file = await resolveCurrentFilePath(
        { kind: "workspace", workspace, root: workRoot, dataDir: this.deps.storage.getDataDir() },
        reqPath,
      );
      if (file.kind === "root-not-found") return { kind: "workspace-root-not-found" };
      if (file.kind === "outside-sandbox") return { kind: "current-file-outside-workspace" };
      if (file.kind === "not-found") return { kind: "current-file-not-found" };
      resolved = file.file.realPath;
    } else {
      let realWorkRoot: string;
      try {
        realWorkRoot = await realpath(workRoot);
      } catch {
        return { kind: "workspace-root-not-found" };
      }
      try {
        resolved = await realpath(resolve(workRoot, reqPath));
      } catch (error: unknown) {
        return isPathMissingError(error)
          ? { kind: "current-file-not-found" }
          : { kind: "current-file-unreadable" };
      }
      if (!isPathWithinRoot(resolved, realWorkRoot)) {
        return { kind: "current-file-outside-workspace" };
      }
    }

    const opened = await openVerifiedFile(resolved);
    if (opened.kind === "error") {
      return opened.status === 404
        ? { kind: "current-file-not-found" }
        : { kind: "current-file-unreadable" };
    }
    try {
      if (!(await opened.handle.stat()).isFile()) return { kind: "current-file-not-file" };
      if (opened.size > MAX_SESSION_FILE_BYTES) {
        return {
          kind: "current-file-too-large",
          maxSizeMegabytes: Math.round(MAX_SESSION_FILE_BYTES / (1024 * 1024)),
        };
      }
      return { kind: "ok", text: await opened.handle.readFile({ encoding: "utf8" }) };
    } catch {
      return { kind: "current-file-unreadable" };
    } finally {
      await opened.handle.close().catch(() => {});
    }
  }

  private async resolveWorkRoot(session: Session): Promise<string | null> {
    const workspace = session.workspaceId
      ? this.deps.storage.getWorkspace(session.workspaceId)
      : undefined;

    if (workspace?.runtime === "sandbox" || workspace?.hostMount) {
      const resolved = await this.resolveSdkCwdOrNull(workspace, session);
      return resolved && (await pathExists(resolved)) ? resolved : null;
    }
    return homedir();
  }

  private async resolveSdkCwdOrNull(
    workspace: Workspace,
    session: Session,
  ): Promise<string | null> {
    try {
      return await resolveSdkSessionCwdAsync(workspace, session, {
        dataDir: this.deps.storage.getDataDir(),
      });
    } catch (error) {
      if (error instanceof WorkspaceWorktreeError) return null;
      throw error;
    }
  }

  private withMobileRenderSegments(
    trace: TraceEvent[],
    includeSegments: boolean,
    serverNames: readonly string[],
  ): TraceEvent[] {
    const toolNames = new Map<string, string>();
    // Results can follow their calls (or lie on a later trace event). Resolve
    // identity before mapping, not from whatever happened to be seen so far.
    const resultDetails = new Map(
      trace
        .filter((e) => e.type === "toolResult" && e.toolCallId)
        .map((e) => [e.toolCallId, e.details]),
    );
    const nestedDetails = new Map(
      trace
        .filter((e) => e.type === "toolResult" && e.toolName)
        .map((e) => [e.toolName, e.details]),
    );
    return trace.map((original) => {
      const event = original.nestedCalls
        ? {
            ...original,
            nestedCalls: {
              ...original.nestedCalls,
              calls: original.nestedCalls.calls.map((call) => {
                const display =
                  resolveToolDisplay(
                    call.name,
                    undefined,
                    nestedDetails.get(call.name),
                    serverNames,
                  ) ?? call.display;
                return { ...call, ...(display ? { display } : {}) };
              }),
            },
          }
        : original;
      if (event.type === "toolCall") {
        const tool = event.tool ?? "unknown";
        toolNames.set(event.id, tool);
        const callSegments = includeSegments
          ? this.mobileRenderers.renderCall(tool, event.args ?? {})
          : undefined;
        const inputPresentation = this.mobileRenderers.inputPresentation(tool);
        const outputPresentation = this.mobileRenderers.outputPresentation(
          tool,
          resultDetails.get(event.id),
        );
        const display =
          event.display ??
          resolveToolDisplay(tool, undefined, resultDetails.get(event.id), serverNames);
        return {
          ...event,
          ...(callSegments ? { callSegments } : {}),
          ...(inputPresentation ? { inputPresentation } : {}),
          ...(outputPresentation ? { outputPresentation } : {}),
          ...(display ? { display } : {}),
        };
      }
      if (event.type === "toolResult") {
        const tool = event.toolName ?? toolNames.get(event.toolCallId ?? "");
        // Project availability from server-owned details before stripping paths
        // at the client boundary, including results whose call is not in this page.
        const outputAvailability = this.mobileRenderers.outputAvailability(event.details);
        const details = sanitizeToolResultDetails(event.details).details;
        const resultSegments =
          includeSegments && tool
            ? this.mobileRenderers.renderResult(tool, details, event.isError === true)
            : undefined;
        const outputPresentation = tool
          ? this.mobileRenderers.outputPresentation(tool, event.details)
          : undefined;
        return {
          ...event,
          ...(event.details !== undefined ? { details } : {}),
          ...(resultSegments ? { resultSegments } : {}),
          ...(outputPresentation ? { outputPresentation } : {}),
          ...(outputAvailability ? { outputAvailability } : {}),
        };
      }
      return event;
    });
  }

  private liveEntryRenderers(sessionId: string): LiveEntryRendererSet | undefined {
    return this.deps.sessionRuntimes?.getEntryRenderers?.(sessionId);
  }

  private traceReadOptions(params: {
    sessionId: string;
    view?: SessionTraceViewMode;
    leafId?: string | null;
    entryRenderers?: LiveEntryRendererSet;
  }): TraceReadOptions {
    return {
      view: params.view ?? "context",
      attachmentDataDir: this.traceBaseDir(),
      attachmentSessionId: params.sessionId,
      ...(params.leafId !== undefined ? { leafId: params.leafId } : {}),
      ...(params.entryRenderers ? { entryRenderers: params.entryRenderers } : {}),
    };
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
