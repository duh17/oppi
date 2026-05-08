import type { ServerResponse } from "node:http";
import { createReadStream } from "node:fs";
import { realpath, stat, access } from "node:fs/promises";
import { extname, join, resolve } from "node:path";
import { homedir } from "node:os";

import { isPathWithinRoot } from "../git-utils.js";
import { resolveSdkSessionCwd } from "../sdk-backend.js";
import type { RouteContext, RouteHelpers } from "./types.js";
import {
  getContentType,
  isBrowseMediaContentType,
  isSensitivePath,
  isStreamingMediaContentType,
} from "./workspace-files.js";

const MAX_SESSION_FILE_BYTES = 10 * 1024 * 1024;
const MAX_TOUCHED_IMAGE_SIZE = 50 * 1024 * 1024; // 50 MB
const MAX_TOUCHED_TEXT_SIZE = 10 * 1024 * 1024; // 10 MB

export interface SessionFileHandlers {
  handleGetSessionFile(
    workspaceId: string,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): Promise<void>;
  handleGetTouchedFile(
    workspaceId: string,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): Promise<void>;
}

export function createSessionFileHandlers(
  ctx: RouteContext,
  helpers: RouteHelpers,
): SessionFileHandlers {
  async function handleGetSessionFile(
    workspaceId: string,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const session = ctx.storage.getSession(sessionId);
    if (!session) {
      helpers.error(res, 404, "Session not found");
      return;
    }
    if (session.workspaceId !== workspaceId) {
      helpers.error(res, 400, "Session does not belong to this workspace");
      return;
    }

    const reqPath = url.searchParams.get("path");
    if (!reqPath) {
      helpers.error(res, 400, "path parameter required");
      return;
    }

    if (isSensitivePath(reqPath)) {
      helpers.error(res, 403, "Access denied: sensitive file");
      return;
    }

    const workRoot = await resolveWorkRoot(session.workspaceId);
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

  async function handleGetTouchedFile(
    workspaceId: string,
    sessionId: string,
    url: URL,
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

    const reqPath = url.searchParams.get("path");
    if (!reqPath) {
      helpers.error(res, 400, "path parameter required");
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

    let realWorkspaceRoot: string;
    try {
      realWorkspaceRoot = await realpath(resolveSdkSessionCwd(workspace));
    } catch {
      helpers.error(res, 404, "Workspace root not found");
      return;
    }

    if (!isPathWithinRoot(resolvedPath, realWorkspaceRoot)) {
      helpers.error(res, 403, "Path outside workspace");
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

  async function resolveWorkRoot(workspaceId: string | undefined): Promise<string | null> {
    const workspace = workspaceId ? ctx.storage.getWorkspace(workspaceId) : undefined;

    if (workspace?.hostMount) {
      const resolved = resolveSdkSessionCwd(workspace);
      return (await pathExists(resolved)) ? resolved : null;
    }
    return homedir();
  }

  return {
    handleGetSessionFile,
    handleGetTouchedFile,
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
