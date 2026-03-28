import type { IncomingMessage, ServerResponse } from "node:http";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { DefaultResourceLoader, SettingsManager, getAgentDir } from "@mariozechner/pi-coding-agent";

import { isValidExtensionName } from "../extension-loader.js";
import {
  CommitDiffError,
  getCommitDetail,
  getCommitFileDiff,
  getCommitLog,
} from "../git-commits.js";
import { getGitStatus } from "../git-status.js";
import { discoverLocalSessions } from "../local-sessions.js";
import { resolveSdkSessionCwd } from "../sdk-backend.js";
import type {
  ContextSummary,
  CreateWorkspaceRequest,
  CreateWorkspaceReviewSessionRequest,
  Session,
  UpdateWorkspaceRequest,
  Workspace,
  WorkspaceReviewSessionResponse,
} from "../types.js";
import { buildWorkspaceReviewDiff, WorkspaceReviewDiffError } from "../workspace-review-diff.js";
import {
  prepareWorkspaceReviewSession,
  WorkspaceReviewSessionError,
} from "../workspace-review-session.js";
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
    const modFile = resolve(
      thisDir,
      "../../node_modules/@mariozechner/pi-coding-agent/dist/core/system-prompt.js",
    );
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

    const localSessions = await discoverLocalSessions(knownFiles);
    helpers.json(res, { sessions: localSessions });
  }

  function handleListWorkspaces(res: ServerResponse): void {
    ctx.storage.ensureDefaultWorkspaces();
    const workspaces = ctx.storage.listWorkspaces().map(removeUnknownSkills);
    helpers.json(res, { workspaces });
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

  async function handleGetWorkspaceGitStatus(wsId: string, res: ServerResponse): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    if (!workspace.hostMount) {
      helpers.json(res, {
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
      });
      return;
    }

    const status = await getGitStatus(workspace.hostMount);
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

  async function handleCreateWorkspaceReviewSession(
    wsId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const body = await helpers.parseBody<CreateWorkspaceReviewSessionRequest>(req);
    const selectedSessionId = body.selectedSessionId?.trim();
    const selectedSession = selectedSessionId
      ? ctx.storage.getSession(selectedSessionId)
      : undefined;

    if (selectedSessionId && !sessionWithinWorkspace(selectedSession, wsId)) {
      helpers.error(res, 404, "Session not found");
      return;
    }

    const validActions = ["review", "reflect", "prepare_commit"] as const;
    if (!validActions.includes(body.action as (typeof validActions)[number])) {
      helpers.error(res, 400, `action must be one of: ${validActions.join(", ")}`);
      return;
    }

    try {
      await handleReviewAction(wsId, workspace, body, selectedSession, res);
    } catch (error) {
      if (error instanceof WorkspaceReviewSessionError) {
        helpers.error(res, error.status, error.message);
        return;
      }

      const message = error instanceof Error ? error.message : "Failed to create review session";
      helpers.error(res, 500, message);
    }
  }

  async function handleReviewAction(
    wsId: string,
    workspace: Workspace,
    body: CreateWorkspaceReviewSessionRequest,
    selectedSession: Session | undefined,
    res: ServerResponse,
  ): Promise<void> {
    const launch = await prepareWorkspaceReviewSession({
      workspaceId: wsId,
      workspace,
      action: body.action,
      paths: Array.isArray(body.paths) ? body.paths : [],
      selectedSession,
    });

    const contextSummary: ContextSummary[] = launch.files.map((f) => ({
      kind: "file_diff" as const,
      path: f.path,
      addedLines: f.addedLines ?? 0,
      removedLines: f.removedLines ?? 0,
    }));

    const model = workspace.lastUsedModel || workspace.defaultModel;
    const session = ctx.storage.createSession(launch.sessionName, model);
    session.workspaceId = workspace.id;
    session.workspaceName = workspace.name;
    session.contextSummary = contextSummary;
    ctx.storage.saveSession(session);

    try {
      ctx.sessions.setPendingPromptPreamble(session.id, launch.preamble);

      await ctx.sessions.startSession(session.id, workspace);
    } catch (error) {
      await ctx.sessions.stopSession(session.id).catch(() => {});
      ctx.storage.deleteSession(session.id);
      throw error;
    }

    const launchedSession =
      ctx.sessions.getActiveSession(session.id) || ctx.storage.getSession(session.id) || session;
    // Ensure contextSummary survives even if getActiveSession returned a copy without it
    if (!launchedSession.contextSummary && contextSummary.length > 0) {
      launchedSession.contextSummary = contextSummary;
    }
    const response: WorkspaceReviewSessionResponse = {
      action: body.action,
      selectedPathCount: launch.files.length,
      session: ctx.ensureSessionContextWindow(launchedSession),
      visiblePrompt: launch.visiblePrompt,
      contextSummary,
    };
    helpers.json(res, response, 201);
  }

  return async ({ method, path, url, req, res }) => {
    if (path === "/local-sessions" && method === "GET") {
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

    const wsGitStatusMatch = path.match(/^\/workspaces\/([^/]+)\/git-status$/);
    if (wsGitStatusMatch && method === "GET") {
      await handleGetWorkspaceGitStatus(wsGitStatusMatch[1], res);
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

    const wsReviewDiffMatch = path.match(/^\/workspaces\/([^/]+)\/review\/diff$/);
    if (wsReviewDiffMatch && method === "GET") {
      await handleGetWorkspaceReviewDiff(wsReviewDiffMatch[1], url, req, res);
      return true;
    }

    const wsReviewSessionMatch = path.match(/^\/workspaces\/([^/]+)\/review\/session$/);
    if (wsReviewSessionMatch && method === "POST") {
      await handleCreateWorkspaceReviewSession(wsReviewSessionMatch[1], req, res);
      return true;
    }

    return false;
  };
}
