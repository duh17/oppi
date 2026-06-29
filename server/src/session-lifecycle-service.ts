import { existsSync, realpathSync } from "node:fs";
import { access, readFile, realpath, rm, unlink } from "node:fs/promises";
import { resolve } from "node:path";

import {
  AgentLaunchService,
  type AgentDefinition,
  type AgentLaunchResult,
  type ThinkingLevel,
} from "./agent-launch-service.js";
import { RuntimeDisconnectedError } from "./agent-runtime-transport.js";
import { isPathWithinRoot } from "./git-utils.js";
import {
  canResumeStoppedMirrorAsOppi,
  promoteStoppedMirrorToOppi,
} from "./mirror-session-resume.js";
import {
  deleteCatalogedLocalSessionPaths,
  invalidateLocalSessionsCache,
  validateCwdAlignment,
  validateLocalSessionPath,
} from "./local-sessions.js";
import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import type { SessionRuntimes } from "./runtime-router.js";
import { resolveSdkSessionCwd } from "./sdk-backend.js";
import { deleteSessionAttachments } from "./session-attachments.js";
import { resolveInitialChatModel } from "./session-model-selection.js";
import type { Storage } from "./storage.js";
import type { ChatAttachmentRef, Session, Workspace } from "./types.js";

const LOCAL_SESSION_META_READ_BYTES = 16_384;

const log = createLogger({ base: { component: "session_lifecycle" } });

export type OpenSessionOwner = "oppi" | "pi-tui";

export interface OpenSessionResult {
  session: Session;
  owner: OpenSessionOwner;
  startedSession: boolean;
}

export interface StopSessionResult {
  session: Session | undefined;
  storedStopOnly: boolean;
}

export interface ForkSessionResult {
  session: Session;
}

export interface DeleteSessionResult {
  session: Session;
  deleted: {
    sqliteMetadata: boolean;
    localPiJsonlFiles: number;
    workspaceAttachmentCopies: boolean;
    generatedMediaAttachments: boolean;
  };
}

export interface ImportLocalSessionResult {
  session: Session;
  created: boolean;
}

export interface CreateWorkspaceSessionResult {
  session: Session;
  createdSession: Session;
  summarySession?: Session;
  prompted?: boolean;
  launchKind?: AgentLaunchResult["kind"];
}

export class SessionLifecycleError extends Error {
  constructor(
    message: string,
    readonly statusCode = 500,
  ) {
    super(message);
    this.name = "SessionLifecycleError";
  }
}

export interface SessionLifecycleServiceDeps {
  storage: Pick<
    Storage,
    | "claimSessionLaunchRecovery"
    | "createSession"
    | "deleteSession"
    | "getDataDir"
    | "getSession"
    | "getWorkspace"
    | "findSessionByLaunchIdempotencyKey"
    | "listSessions"
    | "saveSession"
  >;
  sessions: {
    startSession(sessionId: string, workspace?: Workspace): Promise<Session>;
    sendPrompt(
      sessionId: string,
      message: string,
      opts?: { attachments?: ChatAttachmentRef[] },
    ): Promise<void>;
    runCommand(sessionId: string, command: Record<string, unknown>): Promise<unknown>;
    stopSession(sessionId: string): Promise<void>;
  };
  sessionRuntimes: Pick<
    SessionRuntimes,
    | "isSessionConnected"
    | "isSessionLive"
    | "getSessionSnapshot"
    | "getActiveSession"
    | "refreshSessionState"
    | "stopSession"
    | "stopSessionIfActive"
  >;
  ensureSessionContextWindow: (session: Session) => Session;
  deleteSearchIndexSession?: (sessionId: string) => void;
}

/**
 * Application service for session lifecycle policy.
 *
 * Transport adapters call this instead of branching on Pi SDK versus terminal
 * mirror ownership. The methods preserve the current HTTP/WS wire behavior
 * while keeping runtime transition rules in one place.
 */
export class SessionLifecycleService {
  constructor(private readonly deps: SessionLifecycleServiceDeps) {}

  async createWorkspaceSession(params: {
    workspace: Workspace;
    name?: string;
    model?: string;
    prompt?: string;
    thinking?: string;
    ephemeral?: boolean;
    worktreeId?: string;
    attachments?: ChatAttachmentRef[];
    idempotencyKey?: string;
    leaseOwner?: string;
  }): Promise<CreateWorkspaceSessionResult> {
    const inlineAgent: AgentDefinition = {
      name: params.name?.trim() || params.workspace.name || "Workspace session",
      sessionDefaults: {
        model: params.model,
        thinkingLevel: params.thinking as ThinkingLevel | undefined,
      },
    };
    const launchService = new AgentLaunchService({
      storage: this.deps.storage,
      sessions: this.deps.sessions,
      ensureSessionContextWindow: this.deps.ensureSessionContextWindow,
    });

    const result = await launchService.launch({
      agent: inlineAgent,
      target: { workspace: params.workspace, worktreeId: params.worktreeId },
      prompt: params.prompt,
      attachments: params.attachments,
      idempotencyKey: params.idempotencyKey,
      leaseOwner: params.leaseOwner,
      sessionName: params.name,
      ephemeral: params.ephemeral,
      source: "workspace-wrapper",
    });

    if (result.kind === "launch_in_progress") {
      throw new SessionLifecycleError("launch_in_progress", 409);
    }

    return {
      session: result.session,
      createdSession: result.createdSession,
      summarySession: result.summarySession,
      ...(params.prompt?.trim() ? { prompted: result.promptDispatch === "delivered" } : {}),
      launchKind: result.kind,
    };
  }

  async resumeWorkspaceSession(params: {
    session: Session;
    workspace: Workspace;
  }): Promise<OpenSessionResult> {
    const session = this.prepareMirrorSessionForOpen(params.session);
    if (session.owner === "pi-tui") {
      const active =
        this.deps.sessionRuntimes.getSessionSnapshot(params.session.id) ?? params.session;
      return {
        session: this.deps.ensureSessionContextWindow(active),
        owner: "pi-tui",
        startedSession: false,
      };
    }

    if (this.deps.sessionRuntimes.isSessionLive(params.session.id)) {
      const active = this.deps.sessionRuntimes.getActiveSession(params.session.id);
      return {
        session: active ? this.deps.ensureSessionContextWindow(active) : params.session,
        owner: "oppi",
        startedSession: false,
      };
    }

    const started = await this.deps.sessions.startSession(params.session.id, params.workspace);
    return {
      session: this.deps.ensureSessionContextWindow(started),
      owner: "oppi",
      startedSession: true,
    };
  }

  async openFocusedSession(params: {
    session: Session;
    workspace?: Workspace;
  }): Promise<OpenSessionResult> {
    const session = this.prepareMirrorSessionForOpen(params.session);
    if (session.owner === "pi-tui") {
      const snapshot =
        this.deps.sessionRuntimes.getSessionSnapshot(params.session.id) ?? params.session;
      return {
        session: this.deps.ensureSessionContextWindow(snapshot),
        owner: "pi-tui",
        startedSession: false,
      };
    }

    const hadActiveSession = this.deps.sessionRuntimes.isSessionLive(params.session.id);
    const started = await this.deps.sessions.startSession(params.session.id, params.workspace);
    return {
      session: this.deps.ensureSessionContextWindow(started),
      owner: "oppi",
      startedSession: !hadActiveSession,
    };
  }

  async importLocalSession(params: {
    workspace: Workspace;
    piSessionFile: string;
    name?: string;
    model?: string;
    worktreeId?: string;
  }): Promise<ImportLocalSessionResult> {
    const validation = validateLocalSessionPath(params.piSessionFile);
    if ("error" in validation) {
      throw new SessionLifecycleError(`Invalid session file: ${validation.error}`, 400);
    }

    // Read identity and CWD from the JSONL header for alignment/coalescing.
    const localHeader = await this.readLocalSessionHeader(validation.path);
    if (!localHeader?.cwd) {
      throw new SessionLifecycleError("Cannot read session CWD from file", 400);
    }

    if (!params.workspace.hostMount) {
      throw new SessionLifecycleError("Workspace has no hostMount configured", 400);
    }

    if (!validateCwdAlignment(localHeader.cwd, params.workspace.hostMount)) {
      throw new SessionLifecycleError(
        `Session CWD (${localHeader.cwd}) is not within workspace path (${params.workspace.hostMount})`,
        400,
      );
    }

    // Extract name and first message from the local session JSONL.
    const localMeta = await this.readLocalSessionMeta(validation.path);
    const existingSession = this.findSessionByPiIdentity({
      path: validation.path,
      piSessionId: localHeader.piSessionId,
    });
    if (existingSession) {
      existingSession.workspaceId = params.workspace.id;
      existingSession.workspaceName = params.workspace.name;
      if (params.worktreeId) {
        existingSession.worktreeId = params.worktreeId;
      }
      existingSession.piSessionFile = validation.path;
      existingSession.piSessionFiles = Array.from(
        new Set([...(existingSession.piSessionFiles ?? []), validation.path]),
      );
      if (localHeader.piSessionId) existingSession.piSessionId = localHeader.piSessionId;
      if (!existingSession.firstMessage && localMeta?.firstMessage) {
        existingSession.firstMessage = localMeta.firstMessage.slice(0, 200);
      }
      if (!existingSession.name && params.name) {
        existingSession.name = params.name;
      }
      this.deps.storage.saveSession(existingSession);
      invalidateLocalSessionsCache();
      return {
        session: this.deps.ensureSessionContextWindow(existingSession),
        created: false,
      };
    }

    let sessionName = params.name;
    if (!sessionName) {
      sessionName = localMeta?.name || localMeta?.firstMessage?.slice(0, 80);
    }

    const modelSelection = resolveInitialChatModel({
      requestModel: params.model,
      // Imports should preserve the source trace model when the client does not
      // explicitly override it. Leaving the model undefined lets Pi restore it
      // from the imported JSONL/session state.
      includeWorkspaceDefault: false,
    });
    const session = this.deps.storage.createSession(sessionName, modelSelection.model);

    session.workspaceId = params.workspace.id;
    session.workspaceName = params.workspace.name;
    if (params.worktreeId) {
      session.worktreeId = params.worktreeId;
    }
    if (localMeta?.firstMessage) {
      session.firstMessage = localMeta.firstMessage.slice(0, 200);
    }
    session.piSessionFile = validation.path;
    session.piSessionFiles = [validation.path];
    if (localHeader.piSessionId) session.piSessionId = localHeader.piSessionId;
    session.runtime = "pi-tui";
    session.status = "stopped";
    session.mirror = { status: "disconnected" };
    this.deps.storage.saveSession(session);
    invalidateLocalSessionsCache();

    return {
      session: this.deps.ensureSessionContextWindow(session),
      created: true,
    };
  }

  async forkSession(params: {
    workspace: Workspace;
    sourceSession: Session;
    entryId: string;
    name?: string;
  }): Promise<ForkSessionResult> {
    await this.deps.sessionRuntimes.refreshSessionState(params.sourceSession.id);

    const latestSource =
      this.deps.storage.getSession(params.sourceSession.id) || params.sourceSession;
    const sourceSessionFile =
      latestSource.piSessionFile ||
      latestSource.piSessionFiles?.[latestSource.piSessionFiles.length - 1];

    if (!sourceSessionFile) {
      throw new SessionLifecycleError("Source session has no trace file to fork from", 409);
    }

    const sourceName = latestSource.name?.trim() || `Session ${latestSource.id.slice(0, 8)}`;
    const requestedName = params.name?.trim();
    const forkName = (
      requestedName && requestedName.length > 0 ? requestedName : `Fork: ${sourceName}`
    ).slice(0, 160);

    const forkModelSelection = resolveInitialChatModel({
      sourceSessionModel: latestSource.model,
      workspace: params.workspace,
    });
    const forkSession = this.deps.storage.createSession(forkName, forkModelSelection.model);

    // Pi records file-level ancestry for forks in the JSONL header (`parentSession`).
    // Timeline forks stay independent root sessions in the workspace list.
    forkSession.workspaceId = params.workspace.id;
    forkSession.workspaceName = params.workspace.name;
    if (latestSource.worktreeId) {
      forkSession.worktreeId = latestSource.worktreeId;
    }
    forkSession.piSessionFile = sourceSessionFile;
    forkSession.piSessionFiles = Array.from(
      new Set([...(latestSource.piSessionFiles || []), sourceSessionFile]),
    );

    if (latestSource.thinkingLevel) forkSession.thinkingLevel = latestSource.thinkingLevel;
    if (latestSource.contextWindow) forkSession.contextWindow = latestSource.contextWindow;

    this.deps.storage.saveSession(forkSession);

    try {
      await this.deps.sessions.startSession(forkSession.id, params.workspace);
      await this.deps.sessions.runCommand(forkSession.id, {
        type: "fork",
        entryId: params.entryId,
      });
      await this.deps.sessionRuntimes.refreshSessionState(forkSession.id);
    } catch (error: unknown) {
      await this.deps.sessions.stopSession(forkSession.id).catch(() => {});
      this.deps.storage.deleteSession(forkSession.id);
      throw error;
    }

    const created = this.deps.storage.getSession(forkSession.id) || forkSession;
    return { session: this.deps.ensureSessionContextWindow(created) };
  }

  async stopSession(session: Session): Promise<StopSessionResult> {
    const hydratedSession = this.deps.ensureSessionContextWindow(session);
    let storedStopOnly = false;
    const markStoredSessionStopped = (reason?: string): void => {
      storedStopOnly = true;
      const stoppedAt = Date.now();
      hydratedSession.status = "stopped";
      hydratedSession.currentTurnStartedAt = undefined;
      hydratedSession.lastActivity = stoppedAt;
      if (hydratedSession.runtime === "pi-tui") {
        hydratedSession.mirror = {
          ...(hydratedSession.mirror ?? { status: "disconnected" }),
          status: "disconnected",
          terminal: {
            ...(hydratedSession.mirror?.terminal ?? {}),
            disconnectedAt: hydratedSession.mirror?.terminal?.disconnectedAt ?? stoppedAt,
            disconnectReason: hydratedSession.mirror?.terminal?.disconnectReason ?? reason,
          },
        };
      }
      this.deps.storage.saveSession(hydratedSession);
    };

    try {
      if (session.runtime === "pi-tui") {
        if (this.deps.sessionRuntimes.isSessionConnected(session.id)) {
          await this.deps.sessionRuntimes.stopSession(session.id);
        } else {
          markStoredSessionStopped("oppi_stop_disconnected_terminal");
        }
      } else if (this.deps.sessionRuntimes.isSessionLive(session.id)) {
        await this.deps.sessionRuntimes.stopSession(session.id);
      } else {
        markStoredSessionStopped();
      }
    } catch (error: unknown) {
      if (
        session.runtime === "pi-tui" &&
        error instanceof RuntimeDisconnectedError &&
        error.runtime === "pi-tui"
      ) {
        markStoredSessionStopped("oppi_stop_disconnected_terminal");
      } else {
        throw error;
      }
    }

    const updatedSession = this.deps.storage.getSession(session.id);
    return {
      session: updatedSession
        ? this.deps.ensureSessionContextWindow(updatedSession)
        : updatedSession,
      storedStopOnly,
    };
  }

  async deleteSession(session: Session): Promise<DeleteSessionResult> {
    await this.deps.sessionRuntimes.stopSessionIfActive(session.id);

    let deletedTracePaths: string[] = [];
    let deletedWorkspaceAttachmentCopies = false;
    try {
      deletedTracePaths = await this.deleteReferencedLocalPiSessionJsonlFiles(session);
      if (deletedTracePaths.length > 0) {
        log.info("sessions.delete.local_pi_traces_deleted", {
          sessionId: session.id,
          deletedTraceCount: deletedTracePaths.length,
        });
      }
      deletedWorkspaceAttachmentCopies = await this.deleteWorkspaceSessionAttachmentCopies(session);
    } catch (error: unknown) {
      log.error("sessions.delete.files_delete_failed", {
        sessionId: session.id,
        error: safeErrorMessage(error),
      });
      throw new SessionLifecycleError("Failed to delete session files", 500);
    }

    const deletedSqliteMetadata = this.deps.storage.deleteSession(session.id);
    this.deps.deleteSearchIndexSession?.(session.id);
    const deletedGeneratedMediaAttachments = deleteSessionAttachments(
      this.deps.storage.getDataDir(),
      session.id,
    );

    return {
      session,
      deleted: {
        sqliteMetadata: deletedSqliteMetadata,
        localPiJsonlFiles: deletedTracePaths.length,
        workspaceAttachmentCopies: deletedWorkspaceAttachmentCopies,
        generatedMediaAttachments: deletedGeneratedMediaAttachments,
      },
    };
  }

  private hydratedSnapshot(session: Session): Session {
    return { ...this.deps.ensureSessionContextWindow(session) };
  }

  private prepareMirrorSessionForOpen(session: Session): { owner: OpenSessionOwner } {
    if (session.runtime !== "pi-tui") {
      return { owner: "oppi" };
    }

    const mirrorConnected = this.deps.sessionRuntimes.isSessionConnected(session.id);
    if (!canResumeStoppedMirrorAsOppi(session, mirrorConnected)) {
      return { owner: "pi-tui" };
    }

    promoteStoppedMirrorToOppi(session);
    this.deps.storage.saveSession(session);
    return { owner: "oppi" };
  }

  private canonicalSessionFilePath(path: string): string {
    const resolved = resolve(path);
    if (!existsSync(resolved)) return resolved;
    try {
      return realpathSync(resolved);
    } catch {
      return resolved;
    }
  }

  private sessionMatchesPiIdentity(
    session: Session,
    identity: { path: string; piSessionId?: string },
  ): boolean {
    if (identity.piSessionId && session.piSessionId === identity.piSessionId) {
      return true;
    }
    if (
      session.piSessionFile &&
      this.canonicalSessionFilePath(session.piSessionFile) === identity.path
    ) {
      return true;
    }
    return (session.piSessionFiles ?? []).some(
      (file) => this.canonicalSessionFilePath(file) === identity.path,
    );
  }

  private findSessionByPiIdentity(identity: {
    path: string;
    piSessionId?: string;
  }): Session | undefined {
    return this.deps.storage
      .listSessions()
      .find((session) => this.sessionMatchesPiIdentity(session, identity));
  }

  /** Read identity fields from a pi session JSONL header (first line). */
  private async readLocalSessionHeader(
    filePath: string,
  ): Promise<{ cwd: string; piSessionId?: string } | null> {
    try {
      const content = await readFile(filePath, "utf8");
      const firstLine = content.split("\n")[0];
      if (!firstLine) return null;
      const header = JSON.parse(firstLine) as Record<string, unknown>;
      const cwd = typeof header.cwd === "string" ? header.cwd : "";
      if (!cwd) return null;
      return {
        cwd,
        ...(typeof header.id === "string" ? { piSessionId: header.id } : {}),
      };
    } catch {
      return null;
    }
  }

  /** Read name and first message from a local JSONL session (first 16KB only). */
  private async readLocalSessionMeta(
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

  private async deleteReferencedLocalPiSessionJsonlFiles(session: Session): Promise<string[]> {
    const existingPaths = await this.collectExistingSessionJsonlPaths(session);
    const deleteTargets = new Set<string>();

    for (const candidate of existingPaths) {
      const validation = validateLocalSessionPath(candidate);
      if ("error" in validation) {
        // Only local pi session files can reappear in local-session discovery.
        // Never unlink arbitrary paths from session metadata.
        log.debug("sessions.delete.skip_non_local_pi_trace", {
          sessionId: session.id,
          path: candidate,
          reason: validation.error,
        });
        continue;
      }
      deleteTargets.add(validation.path);
    }

    const deletedPaths = Array.from(deleteTargets);
    if (deletedPaths.length > 0) {
      deleteCatalogedLocalSessionPaths(deletedPaths, { dataDir: this.deps.storage.getDataDir() });
    }

    for (const target of deletedPaths) {
      await unlink(target);
    }

    if (deletedPaths.length > 0) {
      invalidateLocalSessionsCache();
    }

    return deletedPaths;
  }

  private async deleteWorkspaceSessionAttachmentCopies(session: Session): Promise<boolean> {
    const workspace = session.workspaceId
      ? this.deps.storage.getWorkspace(session.workspaceId)
      : undefined;
    if (!workspace?.hostMount) return false;

    const workRoot = resolveSdkSessionCwd(workspace);
    if (!(await pathExists(workRoot))) return false;

    const workRootReal = await realpath(workRoot);
    const attachmentsRoot = resolve(workRootReal, ".pi", "attachments");
    const sessionAttachmentsDir = resolve(attachmentsRoot, session.id);
    if (!isPathWithinRoot(sessionAttachmentsDir, attachmentsRoot)) {
      throw new Error("Refusing to delete session attachments outside workspace attachment root");
    }

    const existed = await pathExists(sessionAttachmentsDir);
    await rm(sessionAttachmentsDir, { recursive: true, force: true });
    return existed;
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
