import type { IncomingMessage, ServerResponse } from "node:http";
import type { Dirent } from "node:fs";
import { opendir } from "node:fs/promises";
import { join, relative } from "node:path";
import { resolveWorkspaceFileRoot, sendFileBytes, statServableFile } from "../current-file.js";
import {
  listDirectoryEntries,
  resolveContainedPath as resolveWorkspaceFilePath,
} from "../directory-listing.js";
import {
  decodeWorkspaceRoutePath,
  SEARCH_IGNORE_DIRS,
  SEARCH_ROOT_IGNORE_DIRS,
} from "../file-serving-policy.js";
import type { DirectoryListingResponse, FileIndexResponse, Workspace } from "../types.js";
import { resolveWorkspaceUserPath } from "../workspace-user-path.js";
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
export {
  listDirectoryEntries,
  resolveContainedPath as resolveWorkspaceFilePath,
} from "../directory-listing.js";

const WALK_MAX_DEPTH = 12;
const MAX_INDEX_PATHS = 50_000;
const MAX_WALK_DIRECTORIES = 10_000;
const MAX_WALK_ENTRIES = 100_000;
const MAX_WALK_ENTRIES_PER_DIRECTORY = MAX_WALK_ENTRIES;

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
    const root = resolveWorkspaceFileRoot(
      workspace,
      url.searchParams.get("worktreeId") ?? undefined,
      ctx.storage.getDataDir(),
    );
    if (!root) helpers.error(res, 404, "Worktree not found");
    return root;
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
    // Host workspaces follow in-tree symlink names; sandbox mounts stay confined.
    const realFile = await resolveWorkspaceFilePath(workspaceRoot, mappedPath, {
      confineSymlinks: workspace.runtime === "sandbox",
    });
    if (!realFile) {
      helpers.error(res, 404, "File not found");
      return;
    }

    const servable = await statServableFile(realFile, requestedPath);
    switch (servable.kind) {
      case "ok":
        await sendFileBytes(req, res, method, servable.file, { rangeLogTag: "workspace-raw" });
        return;
      case "not-file":
        helpers.error(res, 404, "Not a file");
        return;
      case "too-large":
        helpers.error(res, 413, `File too large (max ${servable.maxSizeMegabytes}MB)`);
        return;
      case "missing":
      case "unreadable":
        helpers.error(res, 404, "File not found");
        return;
    }
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
    const result = await listDirectoryEntries(workspaceRoot, mappedPath, {
      confineSymlinks: workspace.runtime === "sandbox",
    });

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

    // GET/HEAD /workspaces/:id/raw/:path — legacy lexically confined bytes for
    // iOS builds that predate currentFiles; see /files/current?origin=workspace.
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
