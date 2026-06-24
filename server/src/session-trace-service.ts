import { homedir, tmpdir } from "node:os";
import { extname, join, resolve } from "node:path";
import { access, readFile, realpath, stat } from "node:fs/promises";

import {
  getContentType,
  isBrowseMediaContentType,
  isSensitivePath,
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
import type { SessionRuntimes } from "./runtime-router.js";
import { resolveSdkSessionCwd } from "./sdk-backend.js";
import type { Storage } from "./storage.js";
import {
  findToolOutput,
  readSessionTrace,
  readSessionTraceByUuid,
  readSessionTraceFromFile,
  readSessionTraceFromFiles,
  type TraceEvent,
  type TraceViewMode,
} from "./trace.js";
import type { Session, Workspace, WorkspaceReviewDiffResponse } from "./types.js";
import { buildDiffHunks } from "./workspace-review-diff.js";

const MAX_SESSION_FILE_BYTES = 10 * 1024 * 1024;

export type SessionTraceViewMode = TraceViewMode;

export interface SessionTraceResult {
  session: Session;
  trace: TraceEvent[];
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
  | { kind: "mutations-not-found" };

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
  | { kind: "path-not-in-session-changes" }
  | { kind: "sensitive-path" }
  | { kind: "file-not-found" }
  | { kind: "workspace-root-not-found" }
  | { kind: "path-outside-workspaces" }
  | { kind: "not-file" }
  | { kind: "file-too-large"; maxSizeMegabytes: number };

export interface SessionTraceServiceDeps {
  storage: Pick<Storage, "getDataDir" | "getSession" | "getWorkspace" | "listWorkspaces">;
  sessionRuntimes: Pick<SessionRuntimes, "getToolFullOutputPath" | "refreshSessionState">;
  ensureSessionContextWindow: (session: Session) => Session;
}

/**
 * Application service for session trace and tool-output read policy.
 *
 * Routes keep ownership validation and HTTP status mapping; this service owns
 * trace source precedence across stored Oppi traces, imported Pi JSONL files,
 * and live runtime refresh metadata.
 */
export class SessionTraceService {
  constructor(private readonly deps: SessionTraceServiceDeps) {}

  async getSessionWithTrace(params: {
    session: Session;
    traceView?: SessionTraceViewMode;
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
      trace: trace || [],
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

    const currentText = await this.readCurrentFileText(params.session, params.path);
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

    const changedFiles = params.session.changeStats?.changedFiles ?? [];
    if (!changedFiles.includes(reqPath)) {
      return { kind: "path-not-in-session-changes" };
    }

    if (isSensitivePath(reqPath)) {
      return { kind: "sensitive-path" };
    }

    const resolvedPath = await this.resolveTouchedFilePath(params.workspace, reqPath);
    if (!resolvedPath) {
      return { kind: "file-not-found" };
    }

    const readableWorkspaceRoots = await this.resolveReadableWorkspaceRoots(params.workspace);
    if (readableWorkspaceRoots.length === 0) {
      return { kind: "workspace-root-not-found" };
    }

    if (!readableWorkspaceRoots.some((root) => isPathWithinRoot(resolvedPath, root))) {
      const sessionCreatedFiles = params.session.changeStats?._sessionCreatedFiles ?? [];
      const isSessionCreatedTempFile =
        sessionCreatedFiles.includes(reqPath) &&
        (await this.resolveReadableSessionTempRoots()).some((root) =>
          isPathWithinRoot(resolvedPath, root),
        );

      if (!isSessionCreatedTempFile) {
        return { kind: "path-outside-workspaces" };
      }
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

  private async readCurrentFileText(session: Session, reqPath: string): Promise<string> {
    const workRoot = await this.resolveWorkRoot(session);
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

  private async resolveWorkRoot(session: Session): Promise<string | null> {
    const workspace = session.workspaceId
      ? this.deps.storage.getWorkspace(session.workspaceId)
      : undefined;

    if (workspace?.hostMount) {
      const resolved = resolveSdkSessionCwd(workspace);
      return (await pathExists(resolved)) ? resolved : null;
    }
    return homedir();
  }

  private async resolveTouchedFilePath(
    workspace: Workspace,
    reqPath: string,
  ): Promise<string | null> {
    let absolutePath: string;
    if (reqPath.startsWith("/")) {
      absolutePath = reqPath;
    } else if (reqPath.startsWith("~")) {
      absolutePath = reqPath.replace(/^~(?=\/|$)/, homedir());
    } else {
      const workspaceRoot = resolveSdkSessionCwd(workspace);
      absolutePath = join(workspaceRoot, reqPath);
    }

    try {
      return await realpath(absolutePath);
    } catch {
      return null;
    }
  }

  private async resolveReadableWorkspaceRoots(currentWorkspace: Workspace): Promise<string[]> {
    const roots: string[] = [];
    const workspaces = [
      currentWorkspace,
      ...this.deps.storage
        .listWorkspaces()
        .filter((workspace) => workspace.id !== currentWorkspace.id),
    ];

    for (const workspace of workspaces) {
      try {
        addUniquePath(roots, await realpath(resolveSdkSessionCwd(workspace)));
      } catch {
        continue;
      }
    }

    return roots;
  }

  private async resolveReadableSessionTempRoots(): Promise<string[]> {
    const candidates = [tmpdir(), "/tmp", "/private/tmp", "/var/tmp"];
    const roots: string[] = [];

    for (const candidate of candidates) {
      try {
        addUniquePath(roots, await realpath(candidate));
      } catch {
        continue;
      }
    }

    return roots;
  }

  private traceBaseDir(): string {
    return this.deps.storage.getDataDir?.() ?? process.cwd();
  }

  private async collectExistingSessionJsonlPaths(session: Session): Promise<string[]> {
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
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

function addUniquePath(paths: string[], path: string): void {
  if (!paths.includes(path)) {
    paths.push(path);
  }
}
