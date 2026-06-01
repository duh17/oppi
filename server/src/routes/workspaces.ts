import { existsSync } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import {
  DefaultResourceLoader,
  SettingsManager,
  getAgentDir,
} from "@earendil-works/pi-coding-agent";

import { isValidExtensionName } from "../extension-loader.js";
import {
  CommitDiffError,
  getCommitDetail,
  getCommitFileDiff,
  getCommitLog,
} from "../git-commits.js";
import { getGitStatus } from "../git-status.js";
import { discoverLocalSessions } from "../local-sessions.js";
import { ReviewCommentStoreError } from "../storage/review-comment-dao.js";
import { resolveSdkSessionCwd } from "../sdk-backend.js";
import { resolveInitialChatModel } from "../session-model-selection.js";
import { hostMountValidationError } from "../host.js";
import type {
  MarkReviewCommentsSentRequest,
  CreateReviewCommentRequest,
  CreateWorkspaceRequest,
  CreateWorkspaceQuickActionSessionRequest,
  GitStatus,
  Session,
  UpdateReviewCommentRequest,
  UpdateWorkspaceRequest,
  Workspace,
  WorkspaceListSummary,
  WorkspaceQuickActionsResponse,
  WorkspaceQuickActionSelectionResponse,
  WorkspaceQuickActionSessionResponse,
} from "../types.js";
import { buildWorkspaceReviewDiff, WorkspaceReviewDiffError } from "../workspace-review-diff.js";
import { buildWorkspaceReviewFilesResponse } from "../workspace-review.js";
import {
  loadWorkspaceQuickActionOptions,
  prepareWorkspaceQuickActionSession,
  WorkspaceQuickActionSessionError,
} from "../workspace-quick-action-session.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

export function createWorkspaceRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  function removeUnknownSkills(workspace: Workspace): Workspace {
    const knownSkills = workspace.skills.filter((name) => ctx.skillRegistry.get(name));
    if (knownSkills.length === workspace.skills.length) {
      return workspace;
    }

    return { ...workspace, skills: knownSkills };
  }

  function unknownSkills(skills: string[]): string[] {
    return skills.filter((name) => !ctx.skillRegistry.get(name));
  }

  function extensionValidationError(extensions: unknown): string | undefined {
    if (extensions === undefined) {
      return undefined;
    }

    if (!Array.isArray(extensions)) {
      return "extensions must be an array";
    }

    const invalid = extensions.filter(
      (name) => typeof name !== "string" || !isValidExtensionName(name),
    );

    if (invalid.length > 0) {
      return `Invalid extension names: ${invalid.join(", ")}`;
    }

    return undefined;
  }

  function allowedPathsValidationError(allowedPaths: unknown): string | undefined {
    if (allowedPaths === undefined) {
      return undefined;
    }

    if (!Array.isArray(allowedPaths)) {
      return "allowedPaths must be an array";
    }

    for (const item of allowedPaths) {
      if (!item || typeof item !== "object") {
        return "allowedPaths entries must be objects";
      }

      const candidate = item as { path?: unknown; access?: unknown };
      if (typeof candidate.path !== "string" || candidate.path.trim().length === 0) {
        return "allowedPaths entries require a non-empty path";
      }

      if (candidate.access !== "read" && candidate.access !== "readwrite") {
        return "allowedPaths access must be read or readwrite";
      }
    }

    return undefined;
  }

  function systemPromptModeValidationError(mode: unknown): string | undefined {
    if (mode === undefined) {
      return undefined;
    }

    if (mode !== "append" && mode !== "replace") {
      return "systemPromptMode must be append or replace";
    }

    return undefined;
  }

  async function loadWorkspaceBaseSystemPrompt(workspace: Workspace): Promise<string> {
    const cwd = resolveSdkSessionCwd(workspace);
    const agentDir = getAgentDir();
    const settingsManager = SettingsManager.create(cwd, agentDir);
    const loader = new DefaultResourceLoader({
      cwd,
      agentDir,
      settingsManager,
      noExtensions: true,
      noSkills: true,
      noPromptTemplates: true,
      noThemes: true,
    });
    await loader.reload();

    // If a custom SYSTEM.md exists, return that.
    const custom = loader.getSystemPrompt();
    if (custom) return custom;

    // Otherwise, generate the built-in Pi base system prompt.
    // buildSystemPrompt isn't in the package's exports map, so import via
    // file URL to bypass Node's package-exports resolution.
    const thisDir = dirname(fileURLToPath(import.meta.url));
    const moduleCandidates = [
      resolve(
        thisDir,
        "../../node_modules/@earendil-works/pi-coding-agent/dist/core/system-prompt.js",
      ),
      resolve(
        thisDir,
        "../../node_modules/@mariozechner/pi-coding-agent/dist/core/system-prompt.js",
      ),
    ];
    const modFile = moduleCandidates.find((candidate) => existsSync(candidate));
    if (!modFile) {
      throw new Error("Unable to locate pi system prompt module in node_modules");
    }
    const { buildSystemPrompt } = (await import(`file://${modFile}`)) as {
      buildSystemPrompt: (opts?: { cwd?: string }) => string;
    };
    return buildSystemPrompt({ cwd });
  }

  async function handleListLocalSessions(res: ServerResponse): Promise<void> {
    const knownFiles = new Set<string>();
    for (const session of ctx.storage.listSessions()) {
      if (session.piSessionFile) {
        knownFiles.add(session.piSessionFile);
      }

      for (const file of session.piSessionFiles ?? []) {
        knownFiles.add(file);
      }
    }

    const localSessions = await discoverLocalSessions(knownFiles, {
      dataDir: ctx.storage.getDataDir(),
    });
    helpers.json(res, { sessions: localSessions });
  }

  function handleListWorkspaces(res: ServerResponse): void {
    const storedWorkspaces = ctx.storage.listWorkspaces();
    const workspaces = storedWorkspaces.map(removeUnknownSkills);
    const { serverNow, summaries } = buildWorkspaceListSummarySnapshot(storedWorkspaces);
    helpers.json(res, { serverNow, workspaces, summaries });
  }

  function buildWorkspaceListSummarySnapshot(workspaces: Workspace[]): {
    serverNow: number;
    summaries: WorkspaceListSummary[];
  } {
    const snapshotByWorkspaceId = new Map(
      ctx.storage
        .listWorkspaceSessionSummarySnapshots()
        .map((snapshot) => [snapshot.workspaceId, snapshot] as const),
    );

    const nowMs = Date.now();
    const askWorkspaceIds = new Set<string>();
    for (const sessionId of ctx.sessions.getActiveSessionIds()) {
      const session = ctx.sessions.getActiveSession(sessionId);
      if (!session?.workspaceId) {
        continue;
      }

      const askMessage = ctx.sessions.getPendingAskMessage(sessionId);
      const hasPendingAsk =
        askMessage?.type === "extension_ui_request" &&
        askMessage.method === "ask" &&
        Boolean(askMessage.questions);
      const hasPendingGenericUI = ctx.sessions.getPendingUIRequestMessages(sessionId).length > 0;
      if (hasPendingAsk || hasPendingGenericUI) {
        askWorkspaceIds.add(session.workspaceId);
      }
    }

    const summaries: WorkspaceListSummary[] = workspaces.map((workspace) => {
      const snapshot = snapshotByWorkspaceId.get(workspace.id);
      const hasAttention = askWorkspaceIds.has(workspace.id) || snapshot?.hasErrorRoot === true;

      return {
        workspaceId: workspace.id,
        activeCount: snapshot?.activeCount ?? 0,
        stoppedCount: snapshot?.stoppedCount ?? 0,
        hasAttention,
        hasErrorRoot: snapshot?.hasErrorRoot === true,
        ...(snapshot?.latestActivity !== undefined
          ? { latestActivity: snapshot.latestActivity }
          : {}),
      };
    });

    return { serverNow: nowMs, summaries };
  }

  async function handleCreateWorkspace(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await helpers.parseBody<CreateWorkspaceRequest>(req);

    if (!body.name) {
      helpers.error(res, 400, "name required");
      return;
    }

    if (!body.skills || !Array.isArray(body.skills)) {
      helpers.error(res, 400, "skills array required");
      return;
    }

    const unknown = unknownSkills(body.skills);
    if (unknown.length > 0) {
      helpers.error(res, 400, `Unknown skills: ${unknown.join(", ")}`);
      return;
    }

    const extensionsError = extensionValidationError(body.extensions);
    if (extensionsError) {
      helpers.error(res, 400, extensionsError);
      return;
    }

    const allowedPathsError = allowedPathsValidationError(body.allowedPaths);
    if (allowedPathsError) {
      helpers.error(res, 400, allowedPathsError);
      return;
    }

    const systemPromptModeError = systemPromptModeValidationError(body.systemPromptMode);
    if (systemPromptModeError) {
      helpers.error(res, 400, systemPromptModeError);
      return;
    }

    const hostMountError = hostMountValidationError(body.hostMount);
    if (hostMountError) {
      helpers.error(res, 400, hostMountError);
      return;
    }

    const workspace = ctx.storage.createWorkspace(body);
    helpers.json(res, { workspace }, 201);
  }

  function handleGetWorkspace(wsId: string, res: ServerResponse): void {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    helpers.json(res, { workspace: removeUnknownSkills(workspace) });
  }

  async function handleGetWorkspaceBaseSystemPrompt(
    wsId: string,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const systemPrompt = await loadWorkspaceBaseSystemPrompt(workspace);
    helpers.json(res, { systemPrompt });
  }

  async function handleUpdateWorkspace(
    wsId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const body = await helpers.parseBody<UpdateWorkspaceRequest>(req);

    if (body.skills) {
      const unknown = unknownSkills(body.skills);
      if (unknown.length > 0) {
        helpers.error(res, 400, `Unknown skills: ${unknown.join(", ")}`);
        return;
      }
    }

    const extensionsError = extensionValidationError(body.extensions);
    if (extensionsError) {
      helpers.error(res, 400, extensionsError);
      return;
    }

    const allowedPathsError = allowedPathsValidationError(body.allowedPaths);
    if (allowedPathsError) {
      helpers.error(res, 400, allowedPathsError);
      return;
    }

    const systemPromptModeError = systemPromptModeValidationError(body.systemPromptMode);
    if (systemPromptModeError) {
      helpers.error(res, 400, systemPromptModeError);
      return;
    }

    const hostMountError = hostMountValidationError(body.hostMount);
    if (hostMountError) {
      helpers.error(res, 400, hostMountError);
      return;
    }

    const updated = ctx.storage.updateWorkspace(wsId, body);
    if (!updated) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    helpers.json(res, { workspace: removeUnknownSkills(updated) });
  }

  function handleDeleteWorkspace(wsId: string, res: ServerResponse): void {
    ctx.storage.deleteWorkspace(wsId);
    helpers.json(res, { ok: true });
  }

  function emptyGitStatus(): GitStatus {
    return {
      isGitRepo: false,
      branch: null,
      headSha: null,
      ahead: null,
      behind: null,
      dirtyCount: 0,
      untrackedCount: 0,
      stagedCount: 0,
      files: [],
      totalFiles: 0,
      addedLines: 0,
      removedLines: 0,
      stashCount: 0,
      lastCommitMessage: null,
      lastCommitDate: null,
      recentCommits: [],
    };
  }

  async function handleGetWorkspaceGitStatus(wsId: string, res: ServerResponse): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    if (!workspace.hostMount) {
      helpers.json(res, emptyGitStatus());
      return;
    }

    const status = await getGitStatus(workspace.hostMount);
    helpers.json(res, status);
  }

  async function handleGetWorkspaceGitChanges(wsId: string, res: ServerResponse): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const gitStatus = workspace.hostMount
      ? await getGitStatus(workspace.hostMount)
      : emptyGitStatus();
    helpers.json(
      res,
      buildWorkspaceReviewFilesResponse({
        workspaceId: wsId,
        gitStatus,
        workspaceRoot: workspace.hostMount,
      }),
    );
  }

  async function handleGetWorkspaceCommitLog(
    wsId: string,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    if (!workspace.hostMount) {
      helpers.json(res, { commits: [], total: 0, hasMore: false });
      return;
    }

    const offset = Math.max(0, parseInt(url.searchParams.get("offset") ?? "0", 10) || 0);
    const limit = Math.min(
      100,
      Math.max(1, parseInt(url.searchParams.get("limit") ?? "20", 10) || 20),
    );

    const result = await getCommitLog(workspace.hostMount, offset, limit);
    helpers.json(res, result);
  }

  async function handleGetWorkspaceCommitDetail(
    wsId: string,
    sha: string,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    if (!workspace.hostMount) {
      helpers.error(res, 404, "Workspace has no host mount");
      return;
    }

    try {
      const detail = await getCommitDetail(workspace.hostMount, sha);
      helpers.json(res, detail);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Failed to get commit detail";
      helpers.error(res, 404, message);
    }
  }

  async function handleGetWorkspaceCommitFileDiff(
    wsId: string,
    sha: string,
    url: URL,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    if (!workspace.hostMount) {
      helpers.error(res, 404, "Workspace has no host mount");
      return;
    }

    const filePath = url.searchParams.get("path") ?? "";

    try {
      const diff = await getCommitFileDiff(workspace.hostMount, sha, filePath, wsId);
      helpers.compressedJson(req, res, diff);
    } catch (error) {
      if (error instanceof CommitDiffError) {
        helpers.error(res, error.status, error.message);
        return;
      }
      const message = error instanceof Error ? error.message : "Failed to get commit diff";
      helpers.error(res, 500, message);
    }
  }

  function sessionWithinWorkspace(
    session: Session | undefined,
    workspaceId: string,
  ): session is Session {
    return !!session && session.workspaceId === workspaceId;
  }

  async function handleGetWorkspaceReviewDiff(
    wsId: string,
    url: URL,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    if (!workspace.hostMount) {
      helpers.error(res, 404, "Workspace review unavailable");
      return;
    }

    try {
      const diff = await buildWorkspaceReviewDiff({
        workspaceId: wsId,
        workspaceRoot: workspace.hostMount,
        path: url.searchParams.get("path") ?? "",
      });
      helpers.compressedJson(req, res, diff);
    } catch (error) {
      if (error instanceof WorkspaceReviewDiffError) {
        helpers.error(res, error.status, error.message);
        return;
      }
      throw error;
    }
  }

  async function handleListReviewComments(
    wsId: string,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const comments = ctx.storage.listReviewComments(wsId, {
      sessionId: url.searchParams.get("sessionId") ?? undefined,
      status: url.searchParams.get("status") ?? undefined,
      path: url.searchParams.get("path") ?? undefined,
    });
    helpers.json(res, { comments });
  }

  async function handleCreateReviewComment(
    wsId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    try {
      const body = await helpers.parseBody<CreateReviewCommentRequest>(req);
      const comment = ctx.storage.createReviewComment(wsId, body);
      helpers.json(res, { comment }, 201);
    } catch (error) {
      if (error instanceof ReviewCommentStoreError) {
        helpers.error(res, error.status, error.message);
        return;
      }
      throw error;
    }
  }

  async function handleUpdateReviewComment(
    wsId: string,
    commentId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    try {
      const body = await helpers.parseBody<UpdateReviewCommentRequest>(req);
      const comment = ctx.storage.updateReviewComment(wsId, commentId, body);
      helpers.json(res, { comment });
    } catch (error) {
      if (error instanceof ReviewCommentStoreError) {
        helpers.error(res, error.status, error.message);
        return;
      }
      throw error;
    }
  }

  async function handleDeleteReviewComment(
    wsId: string,
    commentId: string,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    try {
      ctx.storage.deleteReviewComment(wsId, commentId);
      helpers.json(res, { ok: true });
    } catch (error) {
      if (error instanceof ReviewCommentStoreError) {
        helpers.error(res, error.status, error.message);
        return;
      }
      throw error;
    }
  }

  async function handleMarkReviewCommentsSent(
    wsId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    try {
      const body = await helpers.parseBody<MarkReviewCommentsSentRequest>(req);
      const comments = ctx.storage.markReviewCommentsSent(wsId, body);
      helpers.json(res, { comments });
    } catch (error) {
      if (error instanceof ReviewCommentStoreError) {
        helpers.error(res, error.status, error.message);
        return;
      }
      throw error;
    }
  }

  async function parseWorkspaceQuickActionSelection(
    wsId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<{
    workspace: Workspace;
    body: CreateWorkspaceQuickActionSessionRequest;
    selectedSession: Session | undefined;
  } | null> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return null;
    }

    const body = await helpers.parseBody<CreateWorkspaceQuickActionSessionRequest>(req);
    const selectedSessionId = body.selectedSessionId?.trim();
    const selectedSession = selectedSessionId
      ? ctx.storage.getSession(selectedSessionId)
      : undefined;

    if (selectedSessionId && !sessionWithinWorkspace(selectedSession, wsId)) {
      helpers.error(res, 404, "Session not found");
      return null;
    }

    const promptTemplateName = body.promptTemplateName?.trim();
    if (!promptTemplateName) {
      helpers.error(res, 400, "promptTemplateName required");
      return null;
    }
    body.promptTemplateName = promptTemplateName;

    return { workspace, body, selectedSession };
  }

  async function handleGetWorkspaceQuickActions(wsId: string, res: ServerResponse): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    try {
      const response: WorkspaceQuickActionsResponse = {
        actions: await loadWorkspaceQuickActionOptions(workspace),
      };
      helpers.json(res, response);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Failed to load quick actions";
      helpers.error(res, 500, message);
    }
  }

  async function handlePrepareWorkspaceQuickActionSelection(
    wsId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const parsed = await parseWorkspaceQuickActionSelection(wsId, req, res);
    if (!parsed) {
      return;
    }

    try {
      const selection = await prepareWorkspaceQuickActionSession({
        workspaceId: wsId,
        workspace: parsed.workspace,
        paths: Array.isArray(parsed.body.paths) ? parsed.body.paths : [],
        selectedSession: parsed.selectedSession,
        promptTemplateName: parsed.body.promptTemplateName,
      });
      const response: WorkspaceQuickActionSelectionResponse = {
        promptTemplateName: selection.promptTemplateName,
        selectedPathCount: selection.files.length,
        visiblePrompt: selection.visiblePrompt,
        filePaths: selection.files.map((f) => f.path),
      };
      helpers.json(res, response);
    } catch (error) {
      if (error instanceof WorkspaceQuickActionSessionError) {
        helpers.error(res, error.status, error.message);
        return;
      }

      const message =
        error instanceof Error ? error.message : "Failed to prepare quick-action selection";
      helpers.error(res, 500, message);
    }
  }

  async function handleCreateWorkspaceQuickActionSession(
    wsId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const parsed = await parseWorkspaceQuickActionSelection(wsId, req, res);
    if (!parsed) {
      return;
    }

    try {
      await handleQuickAction(wsId, parsed.workspace, parsed.body, parsed.selectedSession, res);
    } catch (error) {
      if (error instanceof WorkspaceQuickActionSessionError) {
        helpers.error(res, error.status, error.message);
        return;
      }

      const message =
        error instanceof Error ? error.message : "Failed to create quick-action session";
      helpers.error(res, 500, message);
    }
  }

  async function handleQuickAction(
    wsId: string,
    workspace: Workspace,
    body: CreateWorkspaceQuickActionSessionRequest,
    selectedSession: Session | undefined,
    res: ServerResponse,
  ): Promise<void> {
    const launch = await prepareWorkspaceQuickActionSession({
      workspaceId: wsId,
      workspace,
      paths: Array.isArray(body.paths) ? body.paths : [],
      selectedSession,
      promptTemplateName: body.promptTemplateName,
    });

    const modelSelection = resolveInitialChatModel({
      sourceSessionModel: selectedSession?.model,
      workspace,
    });
    const session = ctx.storage.createSession(launch.sessionName, modelSelection.model);
    session.workspaceId = workspace.id;
    session.workspaceName = workspace.name;
    ctx.storage.saveSession(session);

    try {
      await ctx.sessions.startSession(session.id, workspace);
    } catch (error) {
      await ctx.sessions.stopSession(session.id).catch(() => {});
      ctx.storage.deleteSession(session.id);
      throw error;
    }

    const launchedSession =
      ctx.sessions.getActiveSession(session.id) || ctx.storage.getSession(session.id) || session;
    const response: WorkspaceQuickActionSessionResponse = {
      promptTemplateName: launch.promptTemplateName,
      selectedPathCount: launch.files.length,
      session: ctx.ensureSessionContextWindow(launchedSession),
      visiblePrompt: launch.visiblePrompt,
      filePaths: launch.files.map((f) => f.path),
    };
    helpers.json(res, response, 201);
  }

  return async ({ method, path, url, req, res }) => {
    if ((path === "/local-sessions" || path === "/tui-sessions") && method === "GET") {
      await handleListLocalSessions(res);
      return true;
    }

    if (path === "/workspaces" && method === "GET") {
      handleListWorkspaces(res);
      return true;
    }

    if (path === "/workspaces" && method === "POST") {
      await handleCreateWorkspace(req, res);
      return true;
    }

    const wsMatch = path.match(/^\/workspaces\/([^/]+)$/);
    if (wsMatch) {
      if (method === "GET") {
        handleGetWorkspace(wsMatch[1], res);
        return true;
      }

      if (method === "PUT") {
        await handleUpdateWorkspace(wsMatch[1], req, res);
        return true;
      }

      if (method === "DELETE") {
        handleDeleteWorkspace(wsMatch[1], res);
        return true;
      }
    }

    const wsBaseSystemPromptMatch = path.match(/^\/workspaces\/([^/]+)\/system-prompt\/base$/);
    if (wsBaseSystemPromptMatch && method === "GET") {
      await handleGetWorkspaceBaseSystemPrompt(wsBaseSystemPromptMatch[1], res);
      return true;
    }

    const wsGitStatusResourceMatch = path.match(/^\/workspaces\/([^/]+)\/git\/status$/);
    if (wsGitStatusResourceMatch && method === "GET") {
      await handleGetWorkspaceGitStatus(wsGitStatusResourceMatch[1], res);
      return true;
    }

    const wsGitChangesMatch = path.match(/^\/workspaces\/([^/]+)\/git\/changes$/);
    if (wsGitChangesMatch && method === "GET") {
      await handleGetWorkspaceGitChanges(wsGitChangesMatch[1], res);
      return true;
    }

    const wsGitDiffMatch = path.match(/^\/workspaces\/([^/]+)\/git\/diff$/);
    if (wsGitDiffMatch && method === "GET") {
      await handleGetWorkspaceReviewDiff(wsGitDiffMatch[1], url, req, res);
      return true;
    }

    const wsGitCommitsMatch = path.match(/^\/workspaces\/([^/]+)\/git\/commits$/);
    if (wsGitCommitsMatch && method === "GET") {
      await handleGetWorkspaceCommitLog(wsGitCommitsMatch[1], url, res);
      return true;
    }

    const wsGitCommitDetailMatch = path.match(/^\/workspaces\/([^/]+)\/git\/commits\/([^/]+)$/);
    if (wsGitCommitDetailMatch && method === "GET") {
      await handleGetWorkspaceCommitDetail(
        wsGitCommitDetailMatch[1],
        wsGitCommitDetailMatch[2],
        res,
      );
      return true;
    }

    const wsGitCommitDiffMatch = path.match(/^\/workspaces\/([^/]+)\/git\/commits\/([^/]+)\/diff$/);
    if (wsGitCommitDiffMatch && method === "GET") {
      await handleGetWorkspaceCommitFileDiff(
        wsGitCommitDiffMatch[1],
        wsGitCommitDiffMatch[2],
        url,
        req,
        res,
      );
      return true;
    }

    const wsReviewCommentsMatch = path.match(/^\/workspaces\/([^/]+)\/review\/comments$/);
    if (wsReviewCommentsMatch) {
      if (method === "GET") {
        await handleListReviewComments(wsReviewCommentsMatch[1], url, res);
        return true;
      }
      if (method === "POST") {
        await handleCreateReviewComment(wsReviewCommentsMatch[1], req, res);
        return true;
      }
    }

    const wsReviewCommentsSentMatch = path.match(/^\/workspaces\/([^/]+)\/review\/comments\/sent$/);
    if (wsReviewCommentsSentMatch && method === "POST") {
      await handleMarkReviewCommentsSent(wsReviewCommentsSentMatch[1], req, res);
      return true;
    }

    const wsReviewCommentMatch = path.match(/^\/workspaces\/([^/]+)\/review\/comments\/([^/]+)$/);
    if (wsReviewCommentMatch) {
      if (method === "PATCH") {
        await handleUpdateReviewComment(wsReviewCommentMatch[1], wsReviewCommentMatch[2], req, res);
        return true;
      }
      if (method === "DELETE") {
        await handleDeleteReviewComment(wsReviewCommentMatch[1], wsReviewCommentMatch[2], res);
        return true;
      }
    }

    const wsQuickActionsMatch = path.match(/^\/workspaces\/([^/]+)\/quick-actions$/);
    if (wsQuickActionsMatch && method === "GET") {
      await handleGetWorkspaceQuickActions(wsQuickActionsMatch[1], res);
      return true;
    }

    const wsQuickActionSelectionMatch = path.match(
      /^\/workspaces\/([^/]+)\/quick-actions\/selection$/,
    );
    if (wsQuickActionSelectionMatch && method === "POST") {
      await handlePrepareWorkspaceQuickActionSelection(wsQuickActionSelectionMatch[1], req, res);
      return true;
    }

    const wsQuickActionSessionMatch = path.match(/^\/workspaces\/([^/]+)\/quick-actions\/session$/);
    if (wsQuickActionSessionMatch && method === "POST") {
      await handleCreateWorkspaceQuickActionSession(wsQuickActionSessionMatch[1], req, res);
      return true;
    }

    return false;
  };
}
