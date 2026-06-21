import type { ServerResponse } from "node:http";
import { createReadStream } from "node:fs";
import { realpath, stat } from "node:fs/promises";
import { extname, join } from "node:path";
import { homedir } from "node:os";

import { isPathWithinRoot } from "../git-utils.js";
import { resolveSdkSessionCwd } from "../sdk-backend.js";
import type { Workspace } from "../types.js";
import type { RouteContext, RouteHelpers } from "./types.js";
import {
  getContentType,
  isBrowseMediaContentType,
  isSensitivePath,
  isStreamingMediaContentType,
} from "./workspace-files.js";

const MAX_TOUCHED_IMAGE_SIZE = 50 * 1024 * 1024; // 50 MB
const MAX_TOUCHED_TEXT_SIZE = 10 * 1024 * 1024; // 10 MB

export interface SessionFileHandlers {
  handleListSessionChanges(
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void>;
  handleGetSessionRaw(
    workspaceId: string,
    sessionId: string,
    requestedPath: string,
    res: ServerResponse,
  ): Promise<void>;
}

export function createSessionFileHandlers(
  ctx: RouteContext,
  helpers: RouteHelpers,
): SessionFileHandlers {
  async function handleListSessionChanges(
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

    const changeStats = session.changeStats;
    helpers.json(res, {
      workspaceId,
      sessionId,
      files: (changeStats?.changedFiles ?? []).map((path) => ({ path })),
      changedFileCount: changeStats?.filesChanged ?? 0,
      changedFilesOverflow: changeStats?.changedFilesOverflow ?? 0,
    });
  }

  async function handleGetSessionRaw(
    workspaceId: string,
    sessionId: string,
    requestedPath: string,
    res: ServerResponse,
  ): Promise<void> {
    if (!requestedPath) {
      helpers.error(res, 400, "path parameter required");
      return;
    }

    await serveTouchedFile(workspaceId, sessionId, requestedPath, res);
  }

  async function serveTouchedFile(
    workspaceId: string,
    sessionId: string,
    reqPath: string,
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

    const changedFiles = session.changeStats?.changedFiles ?? [];
    if (!changedFiles.includes(reqPath)) {
      helpers.error(res, 403, "Path not in session changed files");
      return;
    }

    if (isSensitivePath(reqPath)) {
      helpers.error(res, 403, "Access denied: sensitive file");
      return;
    }

    let absolutePath: string;
    if (reqPath.startsWith("/")) {
      absolutePath = reqPath;
    } else if (reqPath.startsWith("~")) {
      absolutePath = reqPath.replace(/^~(?=\/|$)/, homedir());
    } else {
      const workspaceRoot = resolveSdkSessionCwd(workspace);
      absolutePath = join(workspaceRoot, reqPath);
    }

    let resolvedPath: string;
    try {
      resolvedPath = await realpath(absolutePath);
    } catch {
      helpers.error(res, 404, "File not found");
      return;
    }

    const readableWorkspaceRoots = await resolveReadableWorkspaceRoots(ctx, workspace);
    if (readableWorkspaceRoots.length === 0) {
      helpers.error(res, 404, "Workspace root not found");
      return;
    }

    if (!readableWorkspaceRoots.some((root) => isPathWithinRoot(resolvedPath, root))) {
      helpers.error(res, 403, "Path outside configured workspaces");
      return;
    }

    let fileStat: Awaited<ReturnType<typeof stat>>;
    try {
      fileStat = await stat(resolvedPath);
    } catch {
      helpers.error(res, 404, "File not found");
      return;
    }

    if (!fileStat.isFile()) {
      helpers.error(res, 400, "Not a file");
      return;
    }

    const ext = extname(resolvedPath).toLowerCase();
    const filename = resolvedPath.split("/").pop() ?? resolvedPath;
    const contentType = getContentType(ext, filename);
    if (!isStreamingMediaContentType(contentType)) {
      const isMedia = isBrowseMediaContentType(contentType);
      const maxSize = isMedia ? MAX_TOUCHED_IMAGE_SIZE : MAX_TOUCHED_TEXT_SIZE;
      if (fileStat.size > maxSize) {
        const limitMB = Math.round(maxSize / (1024 * 1024));
        helpers.error(res, 413, `File too large (max ${limitMB}MB)`);
        return;
      }
    }

    res.writeHead(200, {
      "Content-Type": contentType,
      "Content-Length": fileStat.size.toString(),
      "Cache-Control": "private, no-cache",
    });
    createReadStream(resolvedPath).pipe(res as NodeJS.WritableStream);
  }

  return {
    handleListSessionChanges,
    handleGetSessionRaw,
  };
}

async function resolveReadableWorkspaceRoots(
  ctx: RouteContext,
  currentWorkspace: Workspace,
): Promise<string[]> {
  const roots: string[] = [];
  const workspaces = [
    currentWorkspace,
    ...ctx.storage.listWorkspaces().filter((workspace) => workspace.id !== currentWorkspace.id),
  ];

  for (const workspace of workspaces) {
    let realWorkspaceRoot: string;
    try {
      realWorkspaceRoot = await realpath(resolveSdkSessionCwd(workspace));
    } catch {
      continue;
    }

    if (!roots.includes(realWorkspaceRoot)) {
      roots.push(realWorkspaceRoot);
    }
  }

  return roots;
}
