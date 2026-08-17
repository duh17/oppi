const HLS_CONTENT_TYPES = new Set(["application/vnd.apple.mpegurl", "application/x-mpegurl"]);

export const MAX_BROWSE_IMAGE_FILE_SIZE = 50 * 1024 * 1024; // 50 MB
export const MAX_BROWSE_TEXT_FILE_SIZE = 10 * 1024 * 1024; // 10 MB

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

export const SEARCH_IGNORE_DIRS = new Set([
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

/** Private Oppi state is ignored only at the workspace root. */
export const SEARCH_ROOT_IGNORE_DIRS = new Set([".pi"]);

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

export function decodeWorkspaceRoutePath(encodedPath: string): string | null {
  try {
    return decodeURIComponent(encodedPath);
  } catch {
    return null;
  }
}

/**
 * Check whether a workspace-relative path points to a sensitive file.
 *
 * Used to omit credential-like names from the fuzzy `/paths` index.
 * Directory listings may still show those names. Workspace `raw` serves
 * owner-requested files that stay inside the workspace.
 */
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
