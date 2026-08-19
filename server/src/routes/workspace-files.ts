import type { IncomingMessage, ServerResponse } from "node:http";
import type { Dirent, Stats } from "node:fs";
import { createReadStream } from "node:fs";
import { opendir, stat, realpath, readdir } from "node:fs/promises";
import { join, extname, relative, isAbsolute } from "node:path";
import {
  decodeWorkspaceRoutePath,
  getContentType,
  isBrowseMediaContentType,
  isSensitivePath,
  isStreamingMediaContentType,
  MAX_BROWSE_IMAGE_FILE_SIZE,
  MAX_BROWSE_TEXT_FILE_SIZE,
  SEARCH_IGNORE_DIRS,
  SEARCH_ROOT_IGNORE_DIRS,
} from "../file-serving-policy.js";
import { parseByteRangeHeader } from "../http-range.js";
import { resolveSdkSessionCwd } from "../sdk-backend.js";
import type {
  DirectoryListingResponse,
  FileEntry,
  FileIndexResponse,
  Workspace,
} from "../types.js";
import { resolveWorkspaceUserPath } from "../workspace-user-path.js";
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
  SEARCH_ROOT_IGNORE_DIRS,
  SENSITIVE_FILE_PATTERNS,
  TEXT_EXTENSIONS,
} from "../file-serving-policy.js";

const MAX_IMAGE_FILE_SIZE = MAX_BROWSE_IMAGE_FILE_SIZE;
const MAX_TEXT_FILE_SIZE = MAX_BROWSE_TEXT_FILE_SIZE;
const MAX_DIR_ENTRIES = 1000;
const WALK_MAX_DEPTH = 12;
const MAX_INDEX_PATHS = 50_000;
const MAX_WALK_DIRECTORIES = 10_000;
const MAX_WALK_ENTRIES = 100_000;
const MAX_WALK_ENTRIES_PER_DIRECTORY = MAX_WALK_ENTRIES;

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
async function resolveWorkspaceRootPath(workspaceRoot: string): Promise<string> {
  try {
    return await realpath(workspaceRoot);
  } catch {
    return workspaceRoot;
  }
}

export async function resolveWorkspaceFilePath(
  workspaceRoot: string,
  requestedPath: string,
): Promise<string | null> {
  // Absolute paths must not be joined onto the root. Node path.join may either
  // discard the root or append the absolute segment; both break sandbox guest
  // paths mapped onto the host mount.
  const joined =
    !requestedPath || requestedPath === "."
      ? workspaceRoot
      : isAbsolute(requestedPath)
        ? requestedPath
        : join(workspaceRoot, requestedPath);

  let realFile: string;
  try {
    realFile = await realpath(joined);
  } catch {
    return null;
  }

  const realRoot = await resolveWorkspaceRootPath(workspaceRoot);
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

interface SearchWalkResult {
  paths: string[];
  truncated: boolean;
}

interface SearchDirectoryReadResult {
  entries: Dirent[];
  truncated: boolean;
  stopTraversal: boolean;
}

function compareSearchNames(lhs: string, rhs: string): number {
  if (lhs === rhs) return 0;
  return lhs < rhs ? -1 : 1;
}

/**
 * Walk the workspace filesystem without consulting Git's ignore rules.
 *
 * Directory streams are bounded before sorting, and both directory and entry
 * budgets include filtered/empty work. Entries read within the bound are
 * sorted before traversal. `Dirent.isDirectory()` is intentionally used
 * without stat or realpath; symbolic links are leaves and are not indexed or
 * followed.
 */
async function walkDirectoryForSearch(root: string): Promise<SearchWalkResult> {
  const paths: string[] = [];
  let truncated = false;
  let pathLimitExceeded = false;
  let globalBudgetExceeded = false;
  let visitedDirectories = 0;
  let scannedEntries = 0;

  async function readDirectoryEntries(dir: string): Promise<SearchDirectoryReadResult> {
    let directory: Awaited<ReturnType<typeof opendir>>;
    try {
      directory = await opendir(dir);
    } catch {
      return { entries: [], truncated: true, stopTraversal: false };
    }

    const entries: Dirent[] = [];
    let directoryTruncated = false;
    let stopTraversal = false;
    let readFailed = false;
    let reachedEnd = false;
    try {
      while (entries.length < MAX_WALK_ENTRIES_PER_DIRECTORY && scannedEntries < MAX_WALK_ENTRIES) {
        const entry = await directory.read();
        if (entry === null) {
          reachedEnd = true;
          break;
        }
        scannedEntries += 1;
        entries.push(entry);
      }

      // Probe once beyond either budget. An extra entry proves that the
      // directory/global budget was exceeded; discard the partial subset so
      // traversal never exposes an arbitrary filesystem-order prefix.
      if (!reachedEnd) {
        const extraEntry = await directory.read();
        if (extraEntry !== null) {
          scannedEntries += 1;
          directoryTruncated = true;
          stopTraversal = scannedEntries > MAX_WALK_ENTRIES;
        } else {
          reachedEnd = true;
        }
      }
    } catch {
      readFailed = true;
    } finally {
      try {
        await directory.close();
      } catch {
        readFailed = true;
      }
    }

    if (readFailed || directoryTruncated) {
      return { entries: [], truncated: true, stopTraversal };
    }

    entries.sort((lhs, rhs) => compareSearchNames(lhs.name, rhs.name));
    return { entries, truncated: false, stopTraversal: false };
  }

  async function walk(dir: string, depth: number): Promise<void> {
    if (pathLimitExceeded || globalBudgetExceeded) return;
    if (depth > WALK_MAX_DEPTH || scannedEntries >= MAX_WALK_ENTRIES) {
      truncated = true;
      return;
    }
    if (visitedDirectories >= MAX_WALK_DIRECTORIES) {
      truncated = true;
      return;
    }
    visitedDirectories += 1;

    const directoryResult = await readDirectoryEntries(dir);
    if (directoryResult.stopTraversal) {
      globalBudgetExceeded = true;
      truncated = true;
      return;
    }
    if (directoryResult.truncated) truncated = true;

    for (const dirent of directoryResult.entries) {
      if (pathLimitExceeded || globalBudgetExceeded) return;
      if (depth === 0 && SEARCH_ROOT_IGNORE_DIRS.has(dirent.name)) continue;
      if (dirent.isSymbolicLink()) continue;

      if (dirent.isDirectory()) {
        if (SEARCH_IGNORE_DIRS.has(dirent.name)) continue;
        if (depth >= WALK_MAX_DEPTH) {
          truncated = true;
          continue;
        }
        await walk(join(dir, dirent.name), depth + 1);
        continue;
      }

      if (dirent.name === ".DS_Store") continue;
      const path = relative(root, join(dir, dirent.name)).replaceAll("\\", "/");
      if (isSensitivePath(path)) continue;

      if (paths.length >= MAX_INDEX_PATHS) {
        pathLimitExceeded = true;
        truncated = true;
        return;
      }
      paths.push(path);
    }
  }

  await walk(root, 0);
  return { paths, truncated };
}

// ─── File Index Cache ───

const FILE_INDEX_TTL_MS = 30_000; // 30 seconds

interface CachedFileIndex {
  paths: string[];
  truncated: boolean;
  timestamp: number;
}

const fileIndexCache = new Map<string, CachedFileIndex>();

/** Get file index for a workspace, using cache when fresh. */
export async function getFileIndex(workspaceRoot: string): Promise<FileIndexResponse> {
  const cached = fileIndexCache.get(workspaceRoot);
  if (cached && Date.now() - cached.timestamp < FILE_INDEX_TTL_MS) {
    return { paths: cached.paths, truncated: cached.truncated };
  }

  const result = await walkDirectoryForSearch(workspaceRoot);
  fileIndexCache.set(workspaceRoot, { ...result, timestamp: Date.now() });
  return result;
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

    const workspaceRoot = resolveWorkspaceRootForFileRequest(workspace, url, res);
    if (!workspaceRoot) return;
    const mappedPath = resolveWorkspaceUserPath({
      workspace,
      requestedPath,
      hostMount: workspaceRoot,
      dataDir: ctx.storage.getDataDir(),
    });
    if (!mappedPath) {
      helpers.error(res, 404, "File not found");
      return;
    }
    const realFile = await resolveWorkspaceFilePath(workspaceRoot, mappedPath);
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
    const mappedPath = resolveWorkspaceUserPath({
      workspace,
      requestedPath: dirPath || ".",
      hostMount: workspaceRoot,
      dataDir: ctx.storage.getDataDir(),
    });
    if (!mappedPath) {
      helpers.error(res, 404, "Directory not found");
      return;
    }
    const result = await listDirectoryEntries(workspaceRoot, mappedPath);

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
    const mappedRoot = resolveWorkspaceUserPath({
      workspace,
      requestedPath: ".",
      hostMount: workspaceRoot,
      dataDir: ctx.storage.getDataDir(),
    });
    if (!mappedRoot) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const response = await getFileIndex(mappedRoot);
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
