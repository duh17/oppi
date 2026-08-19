import type { IncomingMessage, ServerResponse } from "node:http";

import {
  CommitDiffError,
  getCommitDetail,
  getCommitFileDiff,
  getCommitLog,
} from "../git-commits.js";
import { getGitStatus, getWorkspaceGitSummary } from "../git-status.js";
import { collectKnownLocalSessionIdentities, discoverLocalSessions } from "../local-sessions.js";
import { safeErrorMessage } from "../log-utils.js";
import { resolveInitialChatModel } from "../session-model-selection.js";
import { isPiTuiTaskRecordSession } from "../pi-tui-session-classification.js";
import { hostMountValidationError } from "../host.js";
import {
  createWorkspaceWorktree,
  hasManagedWorkspaceWorktreeDirectory,
  listWorkspaceWorktrees,
  openWorkspaceWorktree,
  previewWorkspaceWorktree,
  removeWorkspaceWorktree,
  resolveWorkspaceWorktree,
  WorkspaceWorktreeError,
} from "../worktrees.js";
import type {
  CreateWorkspaceRequest,
  CreateWorkspaceQuickActionSessionRequest,
  GitStatus,
  Session,
  UpdateWorkspaceRequest,
  Workspace,
  WorkspaceGitSummary,
  WorkspaceListSummary,
  WorkspaceQuickActionsResponse,
  WorkspaceQuickActionSelectionResponse,
  WorkspaceQuickActionSessionResponse,
  CreateWorkspaceWorktreeRequest,
  OpenWorkspaceWorktreeRequest,
  PreviewWorkspaceWorktreeRequest,
} from "../types.js";
import { buildWorkspaceReviewDiff, WorkspaceReviewDiffError } from "../workspace-review-diff.js";
import {
  loadWorkspaceQuickActionOptions,
  prepareWorkspaceQuickActionSession,
  WorkspaceQuickActionSessionError,
} from "../workspace-quick-action-session.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";
import { deleteWorkspaceAndStopVm } from "../workspace-sandbox-lifecycle.js";
import {
  hasPendingBlockingUIRequest,
  type PendingUIRequestProvider,
} from "../session-attention.js";

export function createWorkspaceRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  function systemPromptModeValidationError(mode: unknown): string | undefined {
    if (mode === undefined) {
      return undefined;
    }

    if (mode !== "append") {
      return "systemPromptMode must be append";
    }

    return undefined;
  }

  async function handleListLocalSessions(res: ServerResponse): Promise<void> {
    const knownPiSessionIdentities = collectKnownLocalSessionIdentities(ctx.storage.listSessions());
    const localSessions = await discoverLocalSessions(knownPiSessionIdentities, {
      dataDir: ctx.storage.getDataDir(),
    });
    helpers.json(res, { sessions: localSessions });
  }

  function pendingUIRequestProvider(): PendingUIRequestProvider {
    return ctx.sessionRuntimes;
  }

  async function handleListWorkspaces(url: URL, res: ServerResponse): Promise<void> {
    const workspaces = ctx.storage.listWorkspaces();
    const { serverNow, summaries } = buildWorkspaceListSummarySnapshot(workspaces);
    if (url.searchParams.get("includeGitSummary") !== "true") {
      helpers.json(res, { serverNow, workspaces, summaries });
      return;
    }

    const gitSummaries: Array<WorkspaceGitSummary | undefined> = [];
    const concurrency = 4;
    for (let index = 0; index < workspaces.length; index += concurrency) {
      const batch = workspaces.slice(index, index + concurrency);
      const batchSummaries = await Promise.all(
        batch.map(async (workspace) => {
          if (workspace.gitStatusEnabled === false || !workspace.hostMount) {
            return { isGitRepo: false, changedCount: 0, ahead: null, behind: null };
          }
          return getWorkspaceGitSummary(workspace.hostMount);
        }),
      );
      gitSummaries.push(...batchSummaries);
    }

    helpers.json(res, {
      serverNow,
      workspaces,
      summaries: summaries.map((summary, index) => ({
        ...summary,
        ...(gitSummaries[index] ? { gitSummary: gitSummaries[index] } : {}),
      })),
    });
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
    const attentionWorkspaceIds = new Set<string>();
    const provider = pendingUIRequestProvider();
    for (const sessionId of provider.getActiveSessionIds()) {
      const session = provider.getActiveSession(sessionId);
      if (!session?.workspaceId) {
        continue;
      }

      if (hasPendingBlockingUIRequest(provider, sessionId)) {
        attentionWorkspaceIds.add(session.workspaceId);
      }
    }

    const summaries: WorkspaceListSummary[] = workspaces.map((workspace) => {
      const snapshot = snapshotByWorkspaceId.get(workspace.id);
      const hasAttention =
        attentionWorkspaceIds.has(workspace.id) || snapshot?.hasErrorRoot === true;

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

    try {
      const workspace = ctx.storage.createWorkspace(body);
      helpers.json(res, { workspace }, 201);
    } catch (error) {
      helpers.error(res, 400, safeErrorMessage(error));
    }
  }

  function handleGetWorkspace(wsId: string, res: ServerResponse): void {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    helpers.json(res, { workspace });
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

    try {
      const updated = ctx.storage.updateWorkspace(wsId, body);
      if (!updated) {
        helpers.error(res, 404, "Workspace not found");
        return;
      }

      helpers.json(res, { workspace: updated });
    } catch (error) {
      helpers.error(res, 400, safeErrorMessage(error));
    }
  }

  async function handleDeleteWorkspace(wsId: string, res: ServerResponse): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (workspace) {
      const dataDir = ctx.storage.getDataDir();
      const hasManagedWorktrees =
        hasManagedWorkspaceWorktreeDirectory(dataDir, wsId) ||
        listWorkspaceWorktrees(workspace, {
          dataDir,
        }).some((worktree) => worktree.managedByOppi === true);
      if (hasManagedWorktrees) {
        helpers.error(
          res,
          409,
          "Workspace has Oppi-managed worktrees; remove them before deleting the workspace",
        );
        return;
      }
    }

    await deleteWorkspaceAndStopVm(wsId, {
      deleteWorkspace: (workspaceId) => ctx.storage.deleteWorkspace(workspaceId),
      stopWorkspaceVm: ctx.stopWorkspaceVm,
    });
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

  function isObjectBody(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
  }

  function rejectNonObjectBody(
    value: unknown,
    res: ServerResponse,
  ): value is Record<string, unknown> {
    if (isObjectBody(value)) return true;
    helpers.error(res, 400, "Request body must be an object");
    return false;
  }

  function handleListWorkspaceWorktrees(wsId: string, res: ServerResponse): void {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    helpers.json(res, {
      workspaceId: wsId,
      worktrees: listWorkspaceWorktrees(workspace, {
        dataDir: ctx.storage.getDataDir(),
        sessionCountsByWorktreeId: workspaceWorktreeSessionCounts(wsId),
      }),
    });
  }

  function handleWorktreeLifecycleError(error: unknown, res: ServerResponse): void {
    if (error instanceof WorkspaceWorktreeError) {
      helpers.error(res, error.statusCode, error.message);
      return;
    }

    const message = error instanceof Error ? error.message : "Workspace worktree operation failed";
    helpers.error(res, 500, message);
  }

  async function handleCreateWorkspaceWorktree(
    wsId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const body = await helpers.parseBody<unknown>(req);
    if (!rejectNonObjectBody(body, res)) return;
    try {
      const worktree = createWorkspaceWorktree(workspace, body as CreateWorkspaceWorktreeRequest, {
        dataDir: ctx.storage.getDataDir(),
        reservedWorktreeIds: new Set(workspaceWorktreeSessionCounts(wsId).keys()),
      });
      helpers.json(res, { workspaceId: wsId, worktree }, 201);
    } catch (error) {
      handleWorktreeLifecycleError(error, res);
    }
  }

  async function handleOpenWorkspaceWorktree(
    wsId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const body = await helpers.parseBody<unknown>(req);
    if (!rejectNonObjectBody(body, res)) return;
    try {
      const worktree = openWorkspaceWorktree(workspace, body as OpenWorkspaceWorktreeRequest, {
        dataDir: ctx.storage.getDataDir(),
      });
      helpers.json(res, { workspaceId: wsId, worktree });
    } catch (error) {
      handleWorktreeLifecycleError(error, res);
    }
  }

  async function handleGetWorkspaceWorktreeStatus(
    wsId: string,
    worktreeId: string,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const worktree = resolveWorkspaceWorktree(workspace, worktreeId, {
      dataDir: ctx.storage.getDataDir(),
    });
    if (!worktree) {
      helpers.error(res, 404, "Worktree not found");
      return;
    }

    const sessionCounts = workspaceWorktreeSessionCounts(wsId);
    const activeSessionCounts = workspaceWorktreeActiveSessionCounts(wsId);
    const status = await getGitStatus(worktree.path);
    helpers.json(res, {
      workspaceId: wsId,
      worktree: {
        ...worktree,
        sessionCount: sessionCounts.get(worktree.id) ?? 0,
        activeSessionCount: activeSessionCounts.get(worktree.id) ?? 0,
      },
      status,
    });
  }

  async function handlePreviewWorkspaceWorktree(
    wsId: string,
    worktreeId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const body = await helpers.parseBody<unknown>(req);
    if (!rejectNonObjectBody(body, res)) return;
    try {
      const preview = previewWorkspaceWorktree(
        workspace,
        worktreeId,
        body as PreviewWorkspaceWorktreeRequest,
        {
          dataDir: ctx.storage.getDataDir(),
        },
      );
      helpers.json(res, { workspaceId: wsId, preview });
    } catch (error) {
      handleWorktreeLifecycleError(error, res);
    }
  }

  function handleRemoveWorkspaceWorktree(
    wsId: string,
    worktreeId: string,
    url: URL,
    res: ServerResponse,
  ): void {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const normalizedWorktreeId = worktreeId.trim();
    const activeSessionCounts = workspaceWorktreeActiveSessionCounts(wsId);
    try {
      const worktree = removeWorkspaceWorktree(workspace, {
        dataDir: ctx.storage.getDataDir(),
        worktreeId: normalizedWorktreeId,
        force: url.searchParams.get("force") === "true",
        activeSessionCount: activeSessionCounts.get(normalizedWorktreeId) ?? 0,
      });
      helpers.json(res, { ok: true, workspaceId: wsId, worktree });
    } catch (error) {
      handleWorktreeLifecycleError(error, res);
    }
  }

  function workspaceWorktreeSessionCounts(workspaceId: string): Map<string, number> {
    const counts = new Map<string, number>();
    const countedSessionIds = new Set<string>();

    const addSession = (session: Session | undefined): void => {
      if (!session || session.workspaceId !== workspaceId) return;
      if (countedSessionIds.has(session.id)) return;
      if (isPiTuiTaskRecordSession(session)) return;

      countedSessionIds.add(session.id);
      const worktreeId = session.worktreeId?.trim() || "main";
      counts.set(worktreeId, (counts.get(worktreeId) ?? 0) + 1);
    };

    for (const session of ctx.storage.listAllWorkspaceSessionSnapshots(workspaceId)) {
      addSession(session);
    }

    for (const sessionId of ctx.sessionRuntimes.getActiveSessionIds()) {
      addSession(ctx.sessionRuntimes.getActiveSession(sessionId));
    }

    return counts;
  }

  function workspaceWorktreeActiveSessionCounts(workspaceId: string): Map<string, number> {
    const counts = new Map<string, number>();
    const countedSessionIds = new Set<string>();
    const addBlockingSession = (session: Session | undefined): void => {
      if (!session || session.workspaceId !== workspaceId) return;
      if (countedSessionIds.has(session.id)) return;
      if (isPiTuiTaskRecordSession(session)) return;
      if (session.status === "stopped" || session.status === "error") return;

      countedSessionIds.add(session.id);
      const worktreeId = session.worktreeId?.trim() || "main";
      counts.set(worktreeId, (counts.get(worktreeId) ?? 0) + 1);
    };

    // Removal is synchronous after this snapshot, so no new activation can
    // interleave on the Node event loop before git worktree remove completes.
    for (const session of ctx.storage.listAllWorkspaceSessionSnapshots(workspaceId)) {
      addBlockingSession(session);
    }
    for (const sessionId of ctx.sessionRuntimes.getActiveSessionIds()) {
      addBlockingSession(ctx.sessionRuntimes.getActiveSession(sessionId));
    }
    return counts;
  }

  function selectedSessionFromQuery(
    workspaceId: string,
    url: URL,
    res: ServerResponse,
  ): { ok: true; selectedSession?: Session } | { ok: false } {
    const selectedSessionId = url.searchParams.get("selectedSessionId")?.trim();
    if (!selectedSessionId) return { ok: true };

    const selectedSession = ctx.storage.getSession(selectedSessionId);
    if (!selectedSession || selectedSession.workspaceId !== workspaceId) {
      helpers.error(res, 404, "Session not found");
      return { ok: false };
    }
    return { ok: true, selectedSession };
  }

  function workspaceCheckoutFromQuery(
    workspace: Workspace,
    workspaceId: string,
    url: URL,
    res: ServerResponse,
  ): { path?: string; selectedSession?: Session } | undefined {
    const selected = selectedSessionFromQuery(workspaceId, url, res);
    if (!selected.ok) return undefined;

    const worktreeId =
      url.searchParams.get("worktreeId")?.trim() ||
      selected.selectedSession?.worktreeId?.trim() ||
      undefined;
    if (!worktreeId) {
      return { path: workspace.hostMount, selectedSession: selected.selectedSession };
    }

    const worktree = resolveWorkspaceWorktree(workspace, worktreeId, {
      dataDir: ctx.storage.getDataDir(),
    });
    if (!worktree) {
      helpers.error(res, 404, "Worktree not found");
      return undefined;
    }

    return { path: worktree.path, selectedSession: selected.selectedSession };
  }

  async function handleGetWorkspaceGitSummary(wsId: string, res: ServerResponse): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    if (workspace.gitStatusEnabled === false || !workspace.hostMount) {
      helpers.json(res, { isGitRepo: false, changedCount: 0, ahead: null, behind: null });
      return;
    }

    const summary = await getWorkspaceGitSummary(workspace.hostMount);
    if (!summary) {
      helpers.error(res, 503, "Workspace Git summary unavailable");
      return;
    }
    helpers.json(res, summary);
  }

  async function handleGetWorkspaceGitStatus(
    wsId: string,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const checkout = workspaceCheckoutFromQuery(workspace, wsId, url, res);
    if (!checkout) return;

    if (!checkout.path) {
      helpers.json(res, emptyGitStatus());
      return;
    }

    const status = await getGitStatus(checkout.path);
    helpers.json(res, status);
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

    const checkout = workspaceCheckoutFromQuery(workspace, wsId, url, res);
    if (!checkout) return;

    if (!checkout.path) {
      helpers.error(res, 404, "Workspace review unavailable");
      return;
    }

    try {
      const diff = await buildWorkspaceReviewDiff({
        workspaceId: wsId,
        workspaceRoot: checkout.path,
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

    const rawBody = await helpers.parseBody<unknown>(req);
    if (!rejectNonObjectBody(rawBody, res)) return null;
    const body = rawBody as unknown as CreateWorkspaceQuickActionSessionRequest;

    if (body.selectedSessionId !== undefined && typeof body.selectedSessionId !== "string") {
      helpers.error(res, 400, "selectedSessionId must be a string");
      return null;
    }
    const selectedSessionId = body.selectedSessionId?.trim();
    const selectedSession = selectedSessionId
      ? ctx.storage.getSession(selectedSessionId)
      : undefined;

    if (selectedSessionId && !sessionWithinWorkspace(selectedSession, wsId)) {
      helpers.error(res, 404, "Session not found");
      return null;
    }

    if (body.promptTemplateName !== undefined && typeof body.promptTemplateName !== "string") {
      helpers.error(res, 400, "promptTemplateName must be a string");
      return null;
    }
    const promptTemplateName = body.promptTemplateName?.trim();
    if (!promptTemplateName) {
      helpers.error(res, 400, "promptTemplateName required");
      return null;
    }
    body.promptTemplateName = promptTemplateName;

    if (body.worktreeId !== undefined) {
      const worktreeId = typeof body.worktreeId === "string" ? body.worktreeId.trim() : "";
      if (!worktreeId) {
        helpers.error(res, 400, "worktreeId must not be empty");
        return null;
      }
      body.worktreeId = worktreeId;
    }

    if (body.commitSha !== undefined) {
      const commitSha = typeof body.commitSha === "string" ? body.commitSha.trim() : "";
      if (!commitSha) {
        helpers.error(res, 400, "commitSha must not be empty");
        return null;
      }
      body.commitSha = commitSha;
    }

    return { workspace, body, selectedSession };
  }

  async function handleGetWorkspaceQuickActions(
    wsId: string,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const selected = selectedSessionFromQuery(wsId, url, res);
    if (!selected.ok) return;

    try {
      const response: WorkspaceQuickActionsResponse = {
        actions: await loadWorkspaceQuickActionOptions(workspace, {
          selectedSession: selected.selectedSession,
          dataDir: ctx.storage.getDataDir(),
          worktreeId: url.searchParams.get("worktreeId")?.trim() || undefined,
        }),
      };
      helpers.json(res, response);
    } catch (error) {
      if (error instanceof WorkspaceQuickActionSessionError) {
        helpers.error(res, error.status, error.message);
        return;
      }

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
        worktreeId: parsed.body.worktreeId,
        commitSha: parsed.body.commitSha,
        promptTemplateName: parsed.body.promptTemplateName,
        dataDir: ctx.storage.getDataDir(),
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
      worktreeId: body.worktreeId,
      commitSha: body.commitSha,
      promptTemplateName: body.promptTemplateName,
      dataDir: ctx.storage.getDataDir(),
    });

    const modelSelection = resolveInitialChatModel({
      sourceSessionModel: selectedSession?.model,
      workspace,
    });
    const session = ctx.storage.createSession(launch.sessionName, modelSelection.model);
    session.workspaceId = workspace.id;
    session.workspaceName = workspace.name;
    const quickActionWorktreeId = body.worktreeId?.trim() || selectedSession?.worktreeId?.trim();
    if (quickActionWorktreeId && quickActionWorktreeId !== "main") {
      session.worktreeId = quickActionWorktreeId;
    }
    ctx.storage.saveSession(session);

    try {
      await ctx.sessions.startSession(session.id, workspace);
    } catch (error) {
      await ctx.sessions.stopSession(session.id).catch(() => {});
      ctx.storage.deleteSession(session.id);
      throw error;
    }

    const launchedSession = ctx.sessionRuntimes.getSessionSnapshot(session.id) || session;
    const hydratedSession = ctx.ensureSessionContextWindow(launchedSession);
    ctx.appEvents?.emitSessionCreated(hydratedSession);
    const response: WorkspaceQuickActionSessionResponse = {
      promptTemplateName: launch.promptTemplateName,
      selectedPathCount: launch.files.length,
      session: hydratedSession,
      visiblePrompt: launch.visiblePrompt,
      filePaths: launch.files.map((f) => f.path),
    };
    helpers.json(res, response, 201);
  }

  return async ({ method, path, url, req, res }) => {
    if (path === "/local-sessions" && method === "GET") {
      await handleListLocalSessions(res);
      return true;
    }

    if (path === "/workspaces" && method === "GET") {
      await handleListWorkspaces(url, res);
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
        await handleDeleteWorkspace(wsMatch[1], res);
        return true;
      }
    }

    const wsWorktreesMatch = path.match(/^\/workspaces\/([^/]+)\/worktrees$/);
    if (wsWorktreesMatch && method === "GET") {
      handleListWorkspaceWorktrees(wsWorktreesMatch[1], res);
      return true;
    }
    if (wsWorktreesMatch && method === "POST") {
      await handleCreateWorkspaceWorktree(wsWorktreesMatch[1], req, res);
      return true;
    }

    const wsWorktreesOpenMatch = path.match(/^\/workspaces\/([^/]+)\/worktrees\/open$/);
    if (wsWorktreesOpenMatch && method === "POST") {
      await handleOpenWorkspaceWorktree(wsWorktreesOpenMatch[1], req, res);
      return true;
    }

    const wsWorktreeStatusMatch = path.match(/^\/workspaces\/([^/]+)\/worktrees\/([^/]+)\/status$/);
    if (wsWorktreeStatusMatch && method === "GET") {
      await handleGetWorkspaceWorktreeStatus(
        wsWorktreeStatusMatch[1],
        decodeURIComponent(wsWorktreeStatusMatch[2]),
        res,
      );
      return true;
    }

    const wsWorktreePreviewMatch = path.match(
      /^\/workspaces\/([^/]+)\/worktrees\/([^/]+)\/preview$/,
    );
    if (wsWorktreePreviewMatch && method === "POST") {
      await handlePreviewWorkspaceWorktree(
        wsWorktreePreviewMatch[1],
        decodeURIComponent(wsWorktreePreviewMatch[2]),
        req,
        res,
      );
      return true;
    }

    const wsWorktreeMatch = path.match(/^\/workspaces\/([^/]+)\/worktrees\/([^/]+)$/);
    if (wsWorktreeMatch && method === "DELETE") {
      handleRemoveWorkspaceWorktree(
        wsWorktreeMatch[1],
        decodeURIComponent(wsWorktreeMatch[2]),
        url,
        res,
      );
      return true;
    }

    const wsGitSummaryMatch = path.match(/^\/workspaces\/([^/]+)\/git\/summary$/);
    if (wsGitSummaryMatch && method === "GET") {
      await handleGetWorkspaceGitSummary(wsGitSummaryMatch[1], res);
      return true;
    }

    const wsGitStatusResourceMatch = path.match(/^\/workspaces\/([^/]+)\/git\/status$/);
    if (wsGitStatusResourceMatch && method === "GET") {
      await handleGetWorkspaceGitStatus(wsGitStatusResourceMatch[1], url, res);
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

    const wsQuickActionsMatch = path.match(/^\/workspaces\/([^/]+)\/quick-actions$/);
    if (wsQuickActionsMatch && method === "GET") {
      await handleGetWorkspaceQuickActions(wsQuickActionsMatch[1], url, res);
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
