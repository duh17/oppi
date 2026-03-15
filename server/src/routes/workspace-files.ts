import type { ServerResponse } from "node:http";
import type { Dirent } from "node:fs";
import { createReadStream } from "node:fs";
import { stat, realpath, readdir } from "node:fs/promises";
import { join, extname, relative } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

import { resolveSdkSessionCwd } from "../sdk-backend.js";
import type { FileEntry } from "../types.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const execFileAsync = promisify(execFile);

// ─── Size limits ───

/** Image files: 50 MB safety valve (streamed, no memory buffering). */
const MAX_IMAGE_FILE_SIZE = 50 * 1024 * 1024;

/** Text/code files in browse mode: 1 MB cap for mobile viewing. */
const MAX_TEXT_FILE_SIZE = 1 * 1024 * 1024;

/** Maximum entries returned from a directory listing. */
const MAX_DIR_ENTRIES = 1000;

/** Maximum results from a file search. */
const MAX_SEARCH_RESULTS = 100;

/** Timeout for git commands. */
const GIT_TIMEOUT_MS = 5000;

/** Max files collected during non-git walk fallback. */
const WALK_MAX_FILES = 10_000;

/** Max recursion depth for non-git walk fallback. */
const WALK_MAX_DEPTH = 12;

// ─── Extension allowlist — images only (for inline markdown references) ───

/** Image-only allowlist for the default (non-browse) file serving mode. */
// periphery:ignore - exported for tests
export const ALLOWED_EXTENSIONS = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"]);

// ─── Content type maps ───

const IMAGE_CONTENT_TYPES: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".svg": "image/svg+xml",
};

const SPECIAL_CONTENT_TYPES: Record<string, string> = {
  ".json": "application/json; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".htm": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".xml": "text/xml; charset=utf-8",
  ".csv": "text/csv; charset=utf-8",
  ".pdf": "application/pdf",
};

// periphery:ignore - exported for tests
export const TEXT_EXTENSIONS = new Set([
  ".txt",
  ".md",
  ".markdown",
  ".rst",
  ".adoc",
  ".ts",
  ".tsx",
  ".js",
  ".jsx",
  ".mjs",
  ".cjs",
  ".json",
  ".jsonl",
  ".json5",
  ".html",
  ".htm",
  ".css",
  ".scss",
  ".sass",
  ".less",
  ".py",
  ".pyi",
  ".rs",
  ".go",
  ".swift",
  ".java",
  ".kt",
  ".kts",
  ".scala",
  ".c",
  ".cpp",
  ".cc",
  ".cxx",
  ".h",
  ".hpp",
  ".hxx",
  ".rb",
  ".php",
  ".lua",
  ".pl",
  ".pm",
  ".r",
  ".sh",
  ".bash",
  ".zsh",
  ".fish",
  ".ps1",
  ".yml",
  ".yaml",
  ".toml",
  ".ini",
  ".cfg",
  ".conf",
  ".xml",
  ".xsl",
  ".xsd",
  ".sql",
  ".graphql",
  ".gql",
  ".proto",
  ".csv",
  ".tsv",
  ".log",
  ".lock",
  ".gitignore",
  ".gitattributes",
  ".editorconfig",
  ".prettierrc",
  ".eslintrc",
  ".babelrc",
  ".tf",
  ".hcl",
  ".ex",
  ".exs",
  ".erl",
  ".hs",
  ".ml",
  ".fs",
  ".dart",
  ".zig",
  ".nim",
  ".patch",
  ".diff",
]);

const TEXT_FILENAMES = new Set([
  "makefile",
  "dockerfile",
  "license",
  "readme",
  "changelog",
  "contributing",
  "authors",
  "codeowners",
  "procfile",
  "gemfile",
  "rakefile",
  "vagrantfile",
  "justfile",
  "brewfile",
]);

// ─── Directories skipped in listings and search walks ───

// periphery:ignore - exported for tests
export const IGNORE_DIRS = new Set([
  ".git",
  "node_modules",
  ".next",
  "dist",
  "build",
  "__pycache__",
  ".cache",
  ".DS_Store",
  "DerivedData",
  ".build",
  "Pods",
  ".svn",
  ".hg",
]);

// ─── Sensitive file denylist (browse mode blocks serving these) ───

// periphery:ignore - exported for tests
export const SENSITIVE_FILE_PATTERNS: RegExp[] = [
  /^\.env($|\.)/, // .env, .env.local, .env.production
  /\.pem$/i, // Private keys / certificates
  /\.key$/i, // Private keys
  /^id_rsa/, // SSH private keys
  /^id_ed25519/, // SSH private keys
  /^id_ecdsa/, // SSH private keys
  /^id_dsa/, // SSH private keys
  /^\.netrc$/, // Network credentials
  /^\.npmrc$/, // npm tokens
  /^\.pypirc$/, // PyPI credentials
  /^\.htpasswd$/, // HTTP authentication
];

const SENSITIVE_PATH_SEGMENTS = new Set([".git"]);

/**
 * Check whether a workspace-relative path points to a sensitive file
 * that should not be served in browse mode.
 *
 * Sensitive files still appear in directory listings (users should know
 * they exist), but their content is not served.
 */
// periphery:ignore - exported for tests
export function isSensitivePath(requestedPath: string): boolean {
  const segments = requestedPath.split("/");

  // Check directory segments for sensitive path components
  for (let i = 0; i < segments.length - 1; i++) {
    if (SENSITIVE_PATH_SEGMENTS.has(segments[i])) return true;
  }

  // Check the filename against sensitive patterns
  const filename = segments[segments.length - 1];
  return SENSITIVE_FILE_PATTERNS.some((p) => p.test(filename));
}

/**
 * Determine the Content-Type for a file in browse mode.
 *
 * Checks image types, special structured types, known text extensions,
 * and well-known extensionless filenames before falling back to
 * application/octet-stream.
 */
// periphery:ignore - exported for tests
export function getContentType(ext: string, filename: string): string {
  const imageType = IMAGE_CONTENT_TYPES[ext];
  if (imageType) return imageType;

  const special = SPECIAL_CONTENT_TYPES[ext];
  if (special) return special;

  if (TEXT_EXTENSIONS.has(ext)) return "text/plain; charset=utf-8";

  if (TEXT_FILENAMES.has(filename.toLowerCase())) return "text/plain; charset=utf-8";

  return "application/octet-stream";
}

// ─── Path resolution ───

/**
 * Resolve and validate a workspace-relative file path.
 *
 * Returns the canonical absolute path if it is valid and accessible, or
 * `null` if the path does not exist or escapes the workspace root via symlinks
 * or `..` traversal.
 */
// periphery:ignore - exported for tests
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

// ─── Directory listing ───

/**
 * List entries in a workspace directory.
 *
 * Returns null if the path doesn't exist or isn't a directory.
 * Skips IGNORE_DIRS entries and .DS_Store files.
 * Sorts: directories first, then files, alphabetical within each group.
 */
// periphery:ignore - exported for tests
export async function listDirectoryEntries(
  workspaceRoot: string,
  dirRelPath: string,
): Promise<{ entries: FileEntry[]; truncated: boolean } | null> {
  const resolvedDir = await resolveWorkspaceFilePath(workspaceRoot, dirRelPath || ".");
  if (!resolvedDir) return null;

  let dirStat: Awaited<ReturnType<typeof stat>>;
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

    // Skip .DS_Store files
    if (dirent.name === ".DS_Store") continue;

    const entryPath = join(resolvedDir, dirent.name);
    try {
      const entryStat = await stat(entryPath);
      const isDir = entryStat.isDirectory();

      // Skip ignored directories (checked after stat to handle symlinks)
      if (isDir && IGNORE_DIRS.has(dirent.name)) continue;

      entries.push({
        name: dirent.name,
        type: isDir ? "directory" : "file",
        size: entryStat.size,
        modifiedAt: Math.floor(entryStat.mtimeMs),
      });
    } catch {
      // Skip entries we can't stat (broken symlinks, permission errors)
      continue;
    }
  }

  entries.sort((a, b) => {
    if (a.type !== b.type) return a.type === "directory" ? -1 : 1;
    return a.name.localeCompare(b.name);
  });

  return { entries, truncated };
}

// ─── File search ───

/**
 * Search for files by path/name substring within a workspace.
 *
 * Uses `git ls-files` for git repos (respects .gitignore), falls back
 * to a recursive walk with IGNORE_DIRS filtering for non-git workspaces.
 */
// periphery:ignore - exported for tests
export async function searchWorkspaceFiles(
  workspaceRoot: string,
  query: string,
): Promise<{ entries: FileEntry[]; truncated: boolean }> {
  if (!query.trim()) return { entries: [], truncated: false };

  const queryLower = query.toLowerCase().trim();
  let filePaths: string[];

  try {
    const { stdout } = await execFileAsync(
      "git",
      ["ls-files", "--cached", "--others", "--exclude-standard"],
      { cwd: workspaceRoot, maxBuffer: 10 * 1024 * 1024, timeout: GIT_TIMEOUT_MS },
    );
    filePaths = stdout.split("\n").filter(Boolean);
  } catch {
    // Not a git repo or git not available — fall back to manual walk
    filePaths = await walkDirectoryForSearch(workspaceRoot);
  }

  const matches = filePaths.filter((p) => p.toLowerCase().includes(queryLower));
  const truncated = matches.length > MAX_SEARCH_RESULTS;
  const limited = matches.slice(0, MAX_SEARCH_RESULTS);

  const entries: FileEntry[] = [];
  for (const relPath of limited) {
    const fullPath = join(workspaceRoot, relPath);
    try {
      const fileStat = await stat(fullPath);
      const pathParts = relPath.split("/");
      entries.push({
        name: pathParts[pathParts.length - 1],
        path: relPath,
        type: fileStat.isDirectory() ? "directory" : "file",
        size: fileStat.size,
        modifiedAt: Math.floor(fileStat.mtimeMs),
      });
    } catch {
      continue;
    }
  }

  return { entries, truncated };
}

/**
 * Walk the workspace directory tree collecting file paths.
 * Used as a fallback when git is not available.
 */
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
        if (IGNORE_DIRS.has(dirent.name)) continue;
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

// ─── Route factory ───

export function createWorkspaceFileRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  /**
   * Default file serving: image-only allowlist for inline markdown references.
   * This is the existing behavior — no changes.
   */
  async function handleGetFile(
    wsId: string,
    requestedPath: string,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const ext = extname(requestedPath).toLowerCase();
    if (!ALLOWED_EXTENSIONS.has(ext)) {
      helpers.error(res, 403, "File type not allowed");
      return;
    }

    const workspaceRoot = resolveSdkSessionCwd(workspace);
    const realFile = await resolveWorkspaceFilePath(workspaceRoot, requestedPath);

    if (!realFile) {
      helpers.error(res, 404, "File not found");
      return;
    }

    let fileStat: Awaited<ReturnType<typeof stat>>;
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

    if (fileStat.size > MAX_IMAGE_FILE_SIZE) {
      helpers.error(res, 413, "File too large (max 50MB)");
      return;
    }

    const contentType = IMAGE_CONTENT_TYPES[ext] ?? "application/octet-stream";
    res.writeHead(200, {
      "Content-Type": contentType,
      "Content-Length": fileStat.size.toString(),
      "Cache-Control": "private, max-age=60",
    });
    createReadStream(realFile).pipe(res as NodeJS.WritableStream);
  }

  /**
   * Browse mode: serve any non-sensitive file with appropriate content type.
   * Text files capped at 1 MB, images at 50 MB.
   */
  async function handleBrowseFile(
    wsId: string,
    requestedPath: string,
    res: ServerResponse,
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

    const workspaceRoot = resolveSdkSessionCwd(workspace);
    const realFile = await resolveWorkspaceFilePath(workspaceRoot, requestedPath);
    if (!realFile) {
      helpers.error(res, 404, "File not found");
      return;
    }

    let fileStat: Awaited<ReturnType<typeof stat>>;
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
    const isImage = ALLOWED_EXTENSIONS.has(ext);
    const maxSize = isImage ? MAX_IMAGE_FILE_SIZE : MAX_TEXT_FILE_SIZE;

    if (fileStat.size > maxSize) {
      const limitMB = Math.round(maxSize / (1024 * 1024));
      helpers.error(res, 413, `File too large (max ${limitMB}MB)`);
      return;
    }

    const filename = requestedPath.split("/").pop() ?? requestedPath;
    const contentType = getContentType(ext, filename);
    res.writeHead(200, {
      "Content-Type": contentType,
      "Content-Length": fileStat.size.toString(),
      "Cache-Control": "private, no-cache",
    });
    createReadStream(realFile).pipe(res as NodeJS.WritableStream);
  }

  /** List directory entries within a workspace. */
  async function handleListDirectory(
    wsId: string,
    requestedPath: string,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const workspaceRoot = resolveSdkSessionCwd(workspace);
    // Strip trailing slash for path resolution
    const dirPath = requestedPath.endsWith("/") ? requestedPath.slice(0, -1) : requestedPath;
    const result = await listDirectoryEntries(workspaceRoot, dirPath);

    if (!result) {
      helpers.error(res, 404, "Directory not found");
      return;
    }

    helpers.json(res, {
      path: requestedPath || "/",
      entries: result.entries,
      truncated: result.truncated,
    });
  }

  /** Search for files by path/name substring. */
  async function handleSearch(
    wsId: string,
    query: string,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const workspaceRoot = resolveSdkSessionCwd(workspace);
    const result = await searchWorkspaceFiles(workspaceRoot, query);
    helpers.json(res, {
      query,
      entries: result.entries,
      truncated: result.truncated,
    });
  }

  return async ({ method, path, url, res }) => {
    // Search: GET /workspaces/:id/files?search=query
    const searchMatch = path.match(/^\/workspaces\/([^/]+)\/files$/);
    if (searchMatch && method === "GET") {
      const searchQuery = url.searchParams.get("search");
      if (searchQuery !== null) {
        await handleSearch(searchMatch[1], searchQuery, res);
        return true;
      }
      // Bare /files without ?search — not a valid route
      helpers.error(res, 400, "Missing search parameter or trailing slash for directory listing");
      return true;
    }

    // Directory listing or file serving: GET /workspaces/:id/files/<path>
    const match = path.match(/^\/workspaces\/([^/]+)\/files\/(.*)$/);
    if (match && method === "GET") {
      const wsId = match[1];
      const requestedPath = match[2];

      // Directory listing: empty path (root) or trailing slash
      if (requestedPath === "" || requestedPath.endsWith("/")) {
        await handleListDirectory(wsId, requestedPath, res);
        return true;
      }

      // File serving: browse mode or default image-only mode
      const mode = url.searchParams.get("mode");
      if (mode === "browse") {
        await handleBrowseFile(wsId, requestedPath, res);
      } else {
        await handleGetFile(wsId, requestedPath, res);
      }
      return true;
    }

    return false;
  };
}
