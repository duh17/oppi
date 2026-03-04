import type { IncomingMessage, ServerResponse } from "node:http";

import { isValidExtensionName } from "../extension-loader.js";
import { buildWorkspaceGraph } from "../graph.js";
import { getGitStatus } from "../git-status.js";
import { discoverLocalSessions } from "../local-sessions.js";
import type { CreateWorkspaceRequest, UpdateWorkspaceRequest, Workspace } from "../types.js";
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

    if (body.memoryNamespace && !ctx.isValidMemoryNamespace(body.memoryNamespace)) {
      helpers.error(res, 400, "memoryNamespace must match [a-zA-Z0-9][a-zA-Z0-9._-]{0,63}");
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

    if (body.memoryNamespace && !ctx.isValidMemoryNamespace(body.memoryNamespace)) {
      helpers.error(res, 400, "memoryNamespace must match [a-zA-Z0-9][a-zA-Z0-9._-]{0,63}");
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
        stashCount: 0,
        lastCommitMessage: null,
        lastCommitDate: null,
      });
      return;
    }

    const status = await getGitStatus(workspace.hostMount);
    helpers.json(res, status);
  }

  function handleGetWorkspaceGraph(workspaceId: string, url: URL, res: ServerResponse): void {
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const sessions = ctx.storage
      .listSessions()
      .filter((session) => session.workspaceId === workspaceId);

    const currentSessionId = url.searchParams.get("sessionId") || undefined;
    if (currentSessionId && !sessions.some((session) => session.id === currentSessionId)) {
      helpers.error(res, 404, "Session not found");
      return;
    }

    const includeParam = url.searchParams.get("include") || "session";
    const includeParts = includeParam
      .split(",")
      .map((part) => part.trim().toLowerCase())
      .filter((part) => part.length > 0);
    const includeEntryGraph = includeParts.includes("entry");

    const entrySessionId = url.searchParams.get("entrySessionId") || undefined;
    const includePaths = url.searchParams.get("includePaths") === "true";

    const activeSessionIds = new Set<string>();
    for (const session of sessions) {
      if (ctx.sessions.isActive(session.id)) {
        activeSessionIds.add(session.id);
      }
    }

    const graph = buildWorkspaceGraph({
      workspaceId,
      sessions,
      activeSessionIds,
      currentSessionId,
      includeEntryGraph,
      entrySessionId,
      includePaths,
    });

    helpers.json(res, { ...graph });
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

    const wsGitStatusMatch = path.match(/^\/workspaces\/([^/]+)\/git-status$/);
    if (wsGitStatusMatch && method === "GET") {
      await handleGetWorkspaceGitStatus(wsGitStatusMatch[1], res);
      return true;
    }

    const wsGraphMatch = path.match(/^\/workspaces\/([^/]+)\/graph$/);
    if (wsGraphMatch && method === "GET") {
      handleGetWorkspaceGraph(wsGraphMatch[1], url, res);
      return true;
    }

    return false;
  };
}
