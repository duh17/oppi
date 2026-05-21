import type { ServerResponse } from "node:http";
import type { Dirent, Stats } from "node:fs";
import { createReadStream } from "node:fs";
import { stat, realpath, readdir } from "node:fs/promises";
import { join, extname, relative } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

import { resolveSdkSessionCwd } from "../sdk-backend.js";
import type { DirectoryListingResponse, FileEntry, FileIndexResponse } from "../types.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const execFileAsync = promisify(execFile);

const MAX_IMAGE_FILE_SIZE = 50 * 1024 * 1024; // 50 MB
const MAX_TEXT_FILE_SIZE = 10 * 1024 * 1024; // 10 MB (browse mode)
const MAX_DIR_ENTRIES = 1000;
const GIT_TIMEOUT_MS = 5000;
const WALK_MAX_FILES = 10_000;
const WALK_MAX_DEPTH = 12;

export const ALLOWED_EXTENSIONS = new Set([
  ".png",
  ".jpg",
  ".jpeg",
  ".gif",
  ".webp",
  ".bmp",
  ".tif",
  ".tiff",
  ".ico",
  ".svg",
]);

const HLS_CONTENT_TYPES = new Set(["application/vnd.apple.mpegurl", "application/x-mpegurl"]);

const IMAGE_CONTENT_TYPES: Record<string, string> = {
  ".apng": "image/apng",
  ".avif": "image/avif",
  ".bmp": "image/bmp",
  ".gif": "image/gif",
  ".heic": "image/heic",
  ".heif": "image/heif",
  ".ico": "image/vnd.microsoft.icon",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".tif": "image/tiff",
  ".tiff": "image/tiff",
  ".webp": "image/webp",
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

const STREAMING_MEDIA_CONTENT_TYPES: Record<string, string> = {
  // Audio
  ".aac": "audio/aac",
  ".aif": "audio/x-aiff",
  ".aifc": "audio/x-aiff",
  ".aiff": "audio/x-aiff",
  ".amr": "audio/amr",
  ".caf": "audio/x-caf",
  ".flac": "audio/flac",
  ".m4a": "audio/mp4",
  ".mid": "audio/midi",
  ".midi": "audio/midi",
  ".mp3": "audio/mpeg",
  ".mpga": "audio/mpeg",
  ".oga": "audio/ogg",
  ".ogg": "audio/ogg",
  ".opus": "audio/opus",
  ".wav": "audio/wav",
  ".wave": "audio/wav",
  ".weba": "audio/webm",

  // Video
  ".3g2": "video/3gpp2",
  ".3gp": "video/3gpp",
  ".avi": "video/x-msvideo",
  ".flv": "video/x-flv",
  ".m2ts": "video/mp2t",
  ".m4v": "video/x-m4v",
  ".mkv": "video/x-matroska",
  ".mov": "video/quicktime",
  ".mp4": "video/mp4",
  ".mpe": "video/mpeg",
  ".mpeg": "video/mpeg",
  ".mpg": "video/mpeg",
  ".ogv": "video/ogg",
  ".qt": "video/quicktime",
  ".webm": "video/webm",
  ".wmv": "video/x-ms-wmv",

  // Playlists / streaming containers
  ".m3u8": "application/vnd.apple.mpegurl",
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
export function decodeWorkspaceRoutePath(encodedPath: string): string | null {
  try {
    return decodeURIComponent(encodedPath);
  } catch {
    return null;
  }
}

export function isSensitivePath(requestedPath: string): boolean {
  const normalizedPath = requestedPath.replaceAll("\\", "/");
  const segments = normalizedPath.split("/");

  // Check directory segments for sensitive path components
  for (let i = 0; i < segments.length - 1; i++) {
    if (SENSITIVE_PATH_SEGMENTS.has(segments[i])) return true;
  }

  // Check the filename against sensitive patterns
  const filename = segments[segments.length - 1];
  return SENSITIVE_FILE_PATTERNS.some((p) => p.test(filename));
}

function normalizeContentType(contentType: string): string {
  return contentType.split(";", 1)[0]?.trim().toLowerCase() ?? contentType.trim().toLowerCase();
}

function normalizeExtension(ext: string, filename: string): string {
  if (ext) return ext.toLowerCase();

  const dotIndex = filename.lastIndexOf(".");
  if (dotIndex <= 0 || dotIndex === filename.length - 1) return "";
  return filename.slice(dotIndex).toLowerCase();
}

export function isStreamingMediaContentType(contentType: string): boolean {
  const normalized = normalizeContentType(contentType);
  return (
    normalized.startsWith("audio/") ||
    normalized.startsWith("video/") ||
    HLS_CONTENT_TYPES.has(normalized)
  );
}

export function isBrowseMediaContentType(contentType: string): boolean {
  const normalized = normalizeContentType(contentType);
  return (
    normalized.startsWith("image/") ||
    normalized === "application/pdf" ||
    isStreamingMediaContentType(normalized)
  );
}

export function getContentType(ext: string, filename: string): string {
  const normalizedExt = normalizeExtension(ext, filename);

  const imageType = IMAGE_CONTENT_TYPES[normalizedExt];
  if (imageType) return imageType;

  const special = SPECIAL_CONTENT_TYPES[normalizedExt];
  if (special) return special;

  if (TEXT_EXTENSIONS.has(normalizedExt)) return "text/plain; charset=utf-8";

  if (TEXT_FILENAMES.has(filename.toLowerCase())) return "text/plain; charset=utf-8";

  const mediaType = STREAMING_MEDIA_CONTENT_TYPES[normalizedExt];
  if (mediaType) return mediaType;

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

  async function handleFileIndex(wsId: string, res: ServerResponse): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const workspaceRoot = resolveSdkSessionCwd(workspace);
    const response = await getFileIndex(workspaceRoot);
    helpers.json(res, response);
  }

  return async ({ method, path, res }) => {
    // GET /workspaces/:id/paths — flat path list for client-side fuzzy search.
    const pathsMatch = path.match(/^\/workspaces\/([^/]+)\/paths$/);
    if (pathsMatch && method === "GET") {
      await handleFileIndex(pathsMatch[1], res);
      return true;
    }

    // GET /workspaces/:id/contents[/path] — directory contents for file browser.
    const contentsRootMatch = path.match(/^\/workspaces\/([^/]+)\/contents$/);
    if (contentsRootMatch && method === "GET") {
      await handleListDirectory(contentsRootMatch[1], "", res);
      return true;
    }

    const contentsMatch = path.match(/^\/workspaces\/([^/]+)\/contents\/(.*)$/);
    if (contentsMatch && method === "GET") {
      const requestedPath = decodeWorkspaceRoutePath(contentsMatch[2]);
      if (requestedPath === null) {
        helpers.error(res, 400, "Invalid file path encoding");
        return true;
      }

      await handleListDirectory(contentsMatch[1], requestedPath, res);
      return true;
    }

    // GET /workspaces/:id/raw/:path — raw bytes for previews/media.
    const rawMatch = path.match(/^\/workspaces\/([^/]+)\/raw\/(.+)$/);
    if (rawMatch && method === "GET") {
      const requestedPath = decodeWorkspaceRoutePath(rawMatch[2]);
      if (requestedPath === null) {
        helpers.error(res, 400, "Invalid file path encoding");
        return true;
      }

      await handleBrowseFile(rawMatch[1], requestedPath, res);
      return true;
    }

    return false;
  };
}
