import type { IncomingMessage, ServerResponse } from "node:http";
import type { Dirent, Stats } from "node:fs";
import { createReadStream } from "node:fs";
import { stat, realpath, readdir } from "node:fs/promises";
import { join, extname, relative } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

import {
  decodeWorkspaceRoutePath,
  getContentType,
  isBrowseMediaContentType,
  isSensitivePath,
  isStreamingMediaContentType,
  MAX_BROWSE_IMAGE_FILE_SIZE,
  MAX_BROWSE_TEXT_FILE_SIZE,
  SEARCH_IGNORE_DIRS,
} from "../file-serving-policy.js";
import { parseByteRangeHeader } from "../http-range.js";
import { resolveSdkSessionCwd } from "../sdk-backend.js";
import type {
  DirectoryListingResponse,
  FileEntry,
  FileIndexResponse,
  Workspace,
} from "../types.js";
import { resolveWorkspaceWorktree } from "../worktrees.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

export {
  ALLOWED_EXTENSIONS,
  decodeWorkspaceRoutePath,
  getContentType,
  isBrowseMediaContentType,
  isSensitivePath,
  isStreamingMediaContentType,
  SEARCH_IGNORE_DIRS,
  SENSITIVE_FILE_PATTERNS,
  TEXT_EXTENSIONS,
} from "../file-serving-policy.js";

const execFileAsync = promisify(execFile);

const MAX_IMAGE_FILE_SIZE = MAX_BROWSE_IMAGE_FILE_SIZE;
const MAX_TEXT_FILE_SIZE = MAX_BROWSE_TEXT_FILE_SIZE;
const MAX_DIR_ENTRIES = 1000;
const GIT_TIMEOUT_MS = 5000;
const WALK_MAX_FILES = 10_000;
const WALK_MAX_DEPTH = 12;

function pipeFileStream(
  filePath: string,
  res: ServerResponse,
  range?: { start: number; end: number },
): void {
  const stream = range
    ? createReadStream(filePath, { start: range.start, end: range.end })
    : createReadStream(filePath);

  stream.on("error", (error) => {
    if (!res.headersSent) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Failed to read file" }));
      return;
    }
    res.destroy(error);
  });
  stream.pipe(res as NodeJS.WritableStream);
}

/**
 * Resolve and validate a workspace-relative file path.
 *
 * Returns the canonical absolute path if it is valid and accessible, or
 * `null` if the path does not exist or escapes the workspace root via symlinks
 * or `..` traversal.
 */
export async function resolveWorkspaceFilePath(
  workspaceRoot: string,
  requestedPath: string,
): Promise<string | null> {
  const joined = join(workspaceRoot, requestedPath);

  let realFile: string;
  try {
    realFile = await realpath(joined);
  } catch {
    return null;
  }

  let realRoot: string;
  try {
    realRoot = await realpath(workspaceRoot);
  } catch {
    realRoot = workspaceRoot;
  }

  const normalizedRoot = realRoot.endsWith("/") ? realRoot : realRoot + "/";
  if (realFile !== realRoot && !realFile.startsWith(normalizedRoot)) {
    return null;
  }

  return realFile;
}

/** List entries in a workspace directory. Returns null if path is invalid or not a directory. */
export async function listDirectoryEntries(
  workspaceRoot: string,
  dirRelPath: string,
): Promise<{ entries: FileEntry[]; truncated: boolean } | null> {
  const resolvedDir = await resolveWorkspaceFilePath(workspaceRoot, dirRelPath || ".");
  if (!resolvedDir) return null;

  let dirStat: Stats;
  try {
    dirStat = await stat(resolvedDir);
  } catch {
    return null;
  }
  if (!dirStat.isDirectory()) return null;

  let dirents: Dirent[];
  try {
    dirents = await readdir(resolvedDir, { withFileTypes: true });
  } catch {
    return null;
  }

  const entries: FileEntry[] = [];
  let truncated = false;

  for (const dirent of dirents) {
    if (entries.length >= MAX_DIR_ENTRIES) {
      truncated = true;
      break;
    }

    const entryPath = join(resolvedDir, dirent.name);
    try {
      const entryStat = await stat(entryPath);
      const isDir = entryStat.isDirectory();

      entries.push({
        name: dirent.name,
        type: isDir ? "directory" : "file",
        size: entryStat.size,
        modifiedAt: Math.floor(entryStat.mtimeMs),
      });
    } catch {
      continue;
    }
  }

  entries.sort((a, b) => {
    if (a.type !== b.type) return a.type === "directory" ? -1 : 1;
    return a.name.localeCompare(b.name);
  });

  return { entries, truncated };
}

async function walkDirectoryForSearch(root: string): Promise<string[]> {
  const results: string[] = [];

  async function walk(dir: string, depth: number): Promise<void> {
    if (depth > WALK_MAX_DEPTH || results.length >= WALK_MAX_FILES) return;

    let dirents: Dirent[];
    try {
      dirents = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }

    for (const dirent of dirents) {
      if (results.length >= WALK_MAX_FILES) return;

      if (dirent.isDirectory()) {
        if (SEARCH_IGNORE_DIRS.has(dirent.name)) continue;
        await walk(join(dir, dirent.name), depth + 1);
      } else {
        if (dirent.name === ".DS_Store") continue;
        results.push(relative(root, join(dir, dirent.name)));
      }
    }
  }

  await walk(root, 0);
  return results;
}

// ─── File Index Cache ───

const FILE_INDEX_TTL_MS = 30_000; // 30 seconds
const MAX_INDEX_PATHS = 50_000;

interface CachedFileIndex {
  paths: string[];
  truncated: boolean;
  timestamp: number;
}

const fileIndexCache = new Map<string, CachedFileIndex>();

/** Collect all workspace-relative file paths (no stat calls, no sensitive filtering). */
async function collectFilePaths(workspaceRoot: string): Promise<string[]> {
  try {
    const { stdout } = await execFileAsync(
      "git",
      ["ls-files", "--cached", "--others", "--exclude-standard"],
      { cwd: workspaceRoot, maxBuffer: 10 * 1024 * 1024, timeout: GIT_TIMEOUT_MS },
    );
    return stdout.split("\n").filter(Boolean);
  } catch {
    return walkDirectoryForSearch(workspaceRoot);
  }
}

/** Get file index for a workspace, using cache when fresh. */
export async function getFileIndex(workspaceRoot: string): Promise<FileIndexResponse> {
  const cached = fileIndexCache.get(workspaceRoot);
  if (cached && Date.now() - cached.timestamp < FILE_INDEX_TTL_MS) {
    return { paths: cached.paths, truncated: cached.truncated };
  }

  const allPaths = await collectFilePaths(workspaceRoot);
  const truncated = allPaths.length > MAX_INDEX_PATHS;
  const paths = truncated ? allPaths.slice(0, MAX_INDEX_PATHS) : allPaths;

  fileIndexCache.set(workspaceRoot, { paths, truncated, timestamp: Date.now() });
  return { paths, truncated };
}

export function createWorkspaceFileRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  function resolveWorkspaceRootForFileRequest(
    workspace: Workspace,
    url: URL,
    res: ServerResponse,
  ): string | null {
    const worktreeId = url.searchParams.get("worktreeId")?.trim();
    if (!worktreeId) {
      return resolveSdkSessionCwd(workspace);
    }

    const worktree = resolveWorkspaceWorktree(workspace, worktreeId, {
      dataDir: ctx.storage.getDataDir(),
    });
    if (!worktree) {
      helpers.error(res, 404, "Worktree not found");
      return null;
    }

    return worktree.path;
  }

  async function handleBrowseFile(
    wsId: string,
    requestedPath: string,
    url: URL,
    req: IncomingMessage,
    res: ServerResponse,
    method: string,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    if (isSensitivePath(requestedPath)) {
      helpers.error(res, 403, "Access denied: sensitive file");
      return;
    }

    const workspaceRoot = resolveWorkspaceRootForFileRequest(workspace, url, res);
    if (!workspaceRoot) return;
    const realFile = await resolveWorkspaceFilePath(workspaceRoot, requestedPath);
    if (!realFile) {
      helpers.error(res, 404, "File not found");
      return;
    }

    let fileStat: Stats;
    try {
      fileStat = await stat(realFile);
    } catch {
      helpers.error(res, 404, "File not found");
      return;
    }

    if (!fileStat.isFile()) {
      helpers.error(res, 404, "Not a file");
      return;
    }

    const ext = extname(requestedPath).toLowerCase();
    const filename = requestedPath.split("/").pop() ?? requestedPath;
    const contentType = getContentType(ext, filename);

    // Streaming media (video/audio/HLS) has no size limit — served via createReadStream
    // with no memory buffering. Images/PDF capped at 50MB, text at 10MB.
    if (!isStreamingMediaContentType(contentType)) {
      const isMedia = isBrowseMediaContentType(contentType);
      const maxSize = isMedia ? MAX_IMAGE_FILE_SIZE : MAX_TEXT_FILE_SIZE;
      if (fileStat.size > maxSize) {
        const limitMB = Math.round(maxSize / (1024 * 1024));
        helpers.error(res, 413, `File too large (max ${limitMB}MB)`);
        return;
      }
    }

    const commonHeaders = {
      "Content-Type": contentType,
      "Cache-Control": "private, no-cache",
      "Accept-Ranges": "bytes",
    };
    const range = parseByteRangeHeader(req.headers?.range, fileStat.size);
    const isHeadRequest = method.toUpperCase() === "HEAD";

    if (range.kind === "invalid" || range.kind === "unsatisfiable") {
      res.writeHead(416, {
        ...commonHeaders,
        "Content-Range": `bytes */${fileStat.size}`,
        "Content-Length": "0",
      });
      res.end();
      return;
    }

    if (range.kind === "valid") {
      const contentLength = range.end - range.start + 1;
      res.writeHead(206, {
        ...commonHeaders,
        "Content-Range": `bytes ${range.start}-${range.end}/${fileStat.size}`,
        "Content-Length": contentLength.toString(),
      });
      if (isHeadRequest) {
        res.end();
        return;
      }
      pipeFileStream(realFile, res, range);
      return;
    }

    res.writeHead(200, {
      ...commonHeaders,
      "Content-Length": fileStat.size.toString(),
    });
    if (isHeadRequest) {
      res.end();
      return;
    }
    pipeFileStream(realFile, res);
  }

  async function handleListDirectory(
    wsId: string,
    requestedPath: string,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const workspaceRoot = resolveWorkspaceRootForFileRequest(workspace, url, res);
    if (!workspaceRoot) return;
    // Strip trailing slash for path resolution
    const dirPath = requestedPath.endsWith("/") ? requestedPath.slice(0, -1) : requestedPath;
    const result = await listDirectoryEntries(workspaceRoot, dirPath);

    if (!result) {
      helpers.error(res, 404, "Directory not found");
      return;
    }

    const response: DirectoryListingResponse = {
      path: requestedPath || "/",
      entries: result.entries,
      truncated: result.truncated,
    };
    helpers.json(res, response);
  }

  async function handleFileIndex(wsId: string, url: URL, res: ServerResponse): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const workspaceRoot = resolveWorkspaceRootForFileRequest(workspace, url, res);
    if (!workspaceRoot) return;

    const response = await getFileIndex(workspaceRoot);
    helpers.json(res, response);
  }

  return async ({ method, path, url, req, res }) => {
    const normalizedMethod = method.toUpperCase();

    // GET /workspaces/:id/paths — flat path list for client-side fuzzy search.
    const pathsMatch = path.match(/^\/workspaces\/([^/]+)\/paths$/);
    if (pathsMatch && normalizedMethod === "GET") {
      await handleFileIndex(pathsMatch[1], url, res);
      return true;
    }

    // GET /workspaces/:id/contents[/path] — directory contents for file browser.
    const contentsRootMatch = path.match(/^\/workspaces\/([^/]+)\/contents$/);
    if (contentsRootMatch && normalizedMethod === "GET") {
      await handleListDirectory(contentsRootMatch[1], "", url, res);
      return true;
    }

    const contentsMatch = path.match(/^\/workspaces\/([^/]+)\/contents\/(.*)$/);
    if (contentsMatch && normalizedMethod === "GET") {
      const requestedPath = decodeWorkspaceRoutePath(contentsMatch[2]);
      if (requestedPath === null) {
        helpers.error(res, 400, "Invalid file path encoding");
        return true;
      }

      await handleListDirectory(contentsMatch[1], requestedPath, url, res);
      return true;
    }

    // GET/HEAD /workspaces/:id/raw/:path — raw bytes for previews/media.
    const rawMatch = path.match(/^\/workspaces\/([^/]+)\/raw\/(.+)$/);
    if (rawMatch && (normalizedMethod === "GET" || normalizedMethod === "HEAD")) {
      const requestedPath = decodeWorkspaceRoutePath(rawMatch[2]);
      if (requestedPath === null) {
        helpers.error(res, 400, "Invalid file path encoding");
        return true;
      }

      await handleBrowseFile(rawMatch[1], requestedPath, url, req, res, normalizedMethod);
      return true;
    }

    return false;
  };
}
