import type { ServerResponse } from "node:http";
import type { Dirent, Stats } from "node:fs";
import { createReadStream } from "node:fs";
import { stat, realpath, readdir } from "node:fs/promises";
import { join, extname, relative } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

import { resolveSdkSessionCwd } from "../sdk-backend.js";
import type { DirectoryListingResponse, FileEntry, FileSearchResponse } from "../types.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const execFileAsync = promisify(execFile);

const MAX_IMAGE_FILE_SIZE = 50 * 1024 * 1024; // 50 MB
const MAX_TEXT_FILE_SIZE = 1 * 1024 * 1024; // 1 MB (browse mode)
const MAX_DIR_ENTRIES = 1000;
const MAX_SEARCH_RESULTS = 100;
const GIT_TIMEOUT_MS = 5000;
const WALK_MAX_FILES = 10_000;
const WALK_MAX_DEPTH = 12;

export const ALLOWED_EXTENSIONS = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"]);

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

export const IGNORE_DIRS = new Set([
  ".git",
  "node_modules",
  ".next",
  "dist",
  "build",
  "__pycache__",
  ".cache",
  "DerivedData",
  ".build",
  "Pods",
  ".svn",
  ".hg",
]);

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

export function getContentType(ext: string, filename: string): string {
  const imageType = IMAGE_CONTENT_TYPES[ext];
  if (imageType) return imageType;

  const special = SPECIAL_CONTENT_TYPES[ext];
  if (special) return special;

  if (TEXT_EXTENSIONS.has(ext)) return "text/plain; charset=utf-8";

  if (TEXT_FILENAMES.has(filename.toLowerCase())) return "text/plain; charset=utf-8";

  return "application/octet-stream";
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

    if (dirent.name === ".DS_Store") continue;

    const entryPath = join(resolvedDir, dirent.name);
    try {
      const entryStat = await stat(entryPath);
      const isDir = entryStat.isDirectory();

      if (isDir && IGNORE_DIRS.has(dirent.name)) continue;

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

/** Search for files by path/name substring. Uses git ls-files when available, walks otherwise. */
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

export function createWorkspaceFileRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
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

    const response: DirectoryListingResponse = {
      path: requestedPath || "/",
      entries: result.entries,
      truncated: result.truncated,
    };
    helpers.json(res, response);
  }

  async function handleSearch(wsId: string, query: string, res: ServerResponse): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const workspaceRoot = resolveSdkSessionCwd(workspace);
    const result = await searchWorkspaceFiles(workspaceRoot, query);
    const response: FileSearchResponse = {
      query,
      entries: result.entries,
      truncated: result.truncated,
    };
    helpers.json(res, response);
  }

  return async ({ method, path, url, res }) => {
    const searchMatch = path.match(/^\/workspaces\/([^/]+)\/files$/);
    if (searchMatch && method === "GET") {
      const searchQuery = url.searchParams.get("search");
      if (searchQuery !== null) {
        await handleSearch(searchMatch[1], searchQuery, res);
        return true;
      }
      helpers.error(res, 400, "Missing search parameter or trailing slash for directory listing");
      return true;
    }

    const match = path.match(/^\/workspaces\/([^/]+)\/files\/(.*)$/);
    if (match && method === "GET") {
      const wsId = match[1];
      const requestedPath = match[2];

      if (requestedPath === "" || requestedPath.endsWith("/")) {
        await handleListDirectory(wsId, requestedPath, res);
        return true;
      }

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
