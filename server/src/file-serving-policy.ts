const HLS_CONTENT_TYPES = new Set(["application/vnd.apple.mpegurl", "application/x-mpegurl"]);

export const MAX_BROWSE_IMAGE_FILE_SIZE = 50 * 1024 * 1024; // 50 MB
export const MAX_BROWSE_TEXT_FILE_SIZE = 10 * 1024 * 1024; // 10 MB
// Illustrated books are far larger than a PDF of the same page count, and the
// phone holds the whole archive in memory while it reads. The client keeps
// everything it derives from that archive small: one chapter at a time, at most
// 4 MiB of XHTML and 16 MiB of inflated text per entry, no images in this slice.
// 100 MiB leaves ~130 MiB of peak client memory for a full-size illustrated
// book, and the reader refuses anything larger than this before it downloads.
export const MAX_BROWSE_BOOK_FILE_SIZE = 100 * 1024 * 1024; // 100 MB
export const MAX_WORKSPACE_FILE_EDIT_BYTES = 1_048_576; // 1 MiB

const TEXT_PLAIN = "text/plain; charset=utf-8";

/** Extensions served as plain text. One row of `FILE_KINDS` below. */
const TEXT_EXTENSIONS = [
  ".txt",
  ".md",
  ".markdown",
  ".org",
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
];

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

/**
 * How the browse routes treat a file: what the phone opens it as, which also
 * picks its size cap (`browseSizeLimit`). `text` covers anything unrecognised.
 */
export type FileKindClass =
  "image" | "pdf" | "usdz" | "book" | "audio" | "video" | "playlist" | "text";

interface FileKindRow {
  readonly kind: FileKindClass;
  readonly contentType: string;
  readonly extensions: readonly string[];
}

/**
 * The one table of file types the server serves: extension to content type and
 * class. A later row never overrides an earlier one for the same extension.
 * The client keeps its own table (`FileKindTable.swift`); `protocol/file-kinds.json`
 * pins the two together for every extension the phone opens as something other
 * than text.
 */
export const FILE_KINDS: readonly FileKindRow[] = [
  { kind: "image", contentType: "image/apng", extensions: [".apng"] },
  { kind: "image", contentType: "image/avif", extensions: [".avif"] },
  { kind: "image", contentType: "image/bmp", extensions: [".bmp"] },
  { kind: "image", contentType: "image/gif", extensions: [".gif"] },
  { kind: "image", contentType: "image/heic", extensions: [".heic"] },
  { kind: "image", contentType: "image/heif", extensions: [".heif"] },
  { kind: "image", contentType: "image/vnd.microsoft.icon", extensions: [".ico"] },
  { kind: "image", contentType: "image/jpeg", extensions: [".jpeg", ".jpg"] },
  { kind: "image", contentType: "image/png", extensions: [".png"] },
  { kind: "image", contentType: "image/svg+xml", extensions: [".svg"] },
  { kind: "image", contentType: "image/tiff", extensions: [".tif", ".tiff"] },
  { kind: "image", contentType: "image/webp", extensions: [".webp"] },

  { kind: "text", contentType: "application/json; charset=utf-8", extensions: [".json"] },
  { kind: "text", contentType: "text/html; charset=utf-8", extensions: [".html", ".htm"] },
  { kind: "text", contentType: "text/css; charset=utf-8", extensions: [".css"] },
  { kind: "text", contentType: "text/xml; charset=utf-8", extensions: [".xml"] },
  { kind: "text", contentType: "text/csv; charset=utf-8", extensions: [".csv"] },
  { kind: "pdf", contentType: "application/pdf", extensions: [".pdf"] },
  { kind: "usdz", contentType: "model/vnd.usdz+zip", extensions: [".usdz"] },
  { kind: "book", contentType: "application/epub+zip", extensions: [".epub"] },
  { kind: "text", contentType: TEXT_PLAIN, extensions: TEXT_EXTENSIONS },

  { kind: "audio", contentType: "audio/aac", extensions: [".aac"] },
  { kind: "audio", contentType: "audio/x-aiff", extensions: [".aif", ".aifc", ".aiff"] },
  { kind: "audio", contentType: "audio/amr", extensions: [".amr"] },
  { kind: "audio", contentType: "audio/x-caf", extensions: [".caf"] },
  { kind: "audio", contentType: "audio/flac", extensions: [".flac"] },
  { kind: "audio", contentType: "audio/mp4", extensions: [".m4a", ".m4b"] },
  { kind: "audio", contentType: "audio/midi", extensions: [".mid", ".midi"] },
  { kind: "audio", contentType: "audio/mpeg", extensions: [".mp3", ".mpga"] },
  { kind: "audio", contentType: "audio/ogg", extensions: [".oga", ".ogg"] },
  { kind: "audio", contentType: "audio/opus", extensions: [".opus"] },
  { kind: "audio", contentType: "audio/wav", extensions: [".wav", ".wave"] },
  { kind: "audio", contentType: "audio/webm", extensions: [".weba"] },

  { kind: "video", contentType: "video/3gpp2", extensions: [".3g2"] },
  { kind: "video", contentType: "video/3gpp", extensions: [".3gp"] },
  { kind: "video", contentType: "video/x-msvideo", extensions: [".avi"] },
  { kind: "video", contentType: "video/x-flv", extensions: [".flv"] },
  { kind: "video", contentType: "video/mp2t", extensions: [".m2ts"] },
  { kind: "video", contentType: "video/x-m4v", extensions: [".m4v"] },
  { kind: "video", contentType: "video/x-matroska", extensions: [".mkv"] },
  { kind: "video", contentType: "video/quicktime", extensions: [".mov", ".qt"] },
  { kind: "video", contentType: "video/mp4", extensions: [".mp4"] },
  { kind: "video", contentType: "video/mpeg", extensions: [".mpe", ".mpeg", ".mpg"] },
  { kind: "video", contentType: "video/ogg", extensions: [".ogv"] },
  { kind: "video", contentType: "video/webm", extensions: [".webm"] },
  { kind: "video", contentType: "video/x-ms-wmv", extensions: [".wmv"] },

  { kind: "playlist", contentType: "application/vnd.apple.mpegurl", extensions: [".m3u8"] },
];

const FILE_KIND_BY_EXTENSION = new Map<string, FileKindRow>();
for (const row of FILE_KINDS) {
  for (const extension of row.extensions) {
    if (!FILE_KIND_BY_EXTENSION.has(extension)) FILE_KIND_BY_EXTENSION.set(extension, row);
  }
}

/** Kinds whose content type is one fixed string, not a `type/` prefix. */
const FILE_KIND_BY_EXACT_CONTENT_TYPE = new Map<string, FileKindClass>(
  FILE_KINDS.filter((row) => ["pdf", "usdz", "book", "playlist"].includes(row.kind)).map((row) => [
    row.contentType,
    row.kind,
  ]),
);

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

/** The class of a content type: its `type/` prefix for image, audio, and video, else the table. */
export function fileKindOfContentType(contentType: string): FileKindClass {
  const normalized = normalizeContentType(contentType);
  if (normalized.startsWith("image/")) return "image";
  if (normalized.startsWith("audio/")) return "audio";
  if (normalized.startsWith("video/")) return "video";
  if (HLS_CONTENT_TYPES.has(normalized)) return "playlist";
  return FILE_KIND_BY_EXACT_CONTENT_TYPE.get(normalized) ?? "text";
}

export function isStreamingMediaContentType(contentType: string): boolean {
  const kind = fileKindOfContentType(contentType);
  return kind === "audio" || kind === "video" || kind === "playlist";
}

export function isBrowseMediaContentType(contentType: string): boolean {
  return fileKindOfContentType(contentType) !== "text";
}

/**
 * A whole book the phone downloads and opens itself. It has its own cap:
 * book files are larger than images, and streaming media has none.
 */
export function isBookContentType(contentType: string): boolean {
  return fileKindOfContentType(contentType) === "book";
}

/**
 * Largest file a whole browse read serves for a content type, in bytes; null
 * for streaming media, which is range-served without buffering and has no
 * cap. An unrecognised type keeps the text cap: an older phone reads it whole.
 * Ranged and HEAD reads are never capped (`statServableFile`).
 */
export function browseSizeLimit(contentType: string): number | null {
  if (isStreamingMediaContentType(contentType)) return null;
  if (isBookContentType(contentType)) return MAX_BROWSE_BOOK_FILE_SIZE;
  if (isBrowseMediaContentType(contentType)) return MAX_BROWSE_IMAGE_FILE_SIZE;
  return MAX_BROWSE_TEXT_FILE_SIZE;
}

export function getContentType(ext: string, filename: string): string {
  const normalizedExt = normalizeExtension(ext, filename);

  const row = FILE_KIND_BY_EXTENSION.get(normalizedExt);
  if (row) return row.contentType;

  if (TEXT_FILENAMES.has(filename.toLowerCase())) return TEXT_PLAIN;

  return "application/octet-stream";
}

/** Markdown, code, JSON, and plain text. Reuses getContentType; not a second stack. */
export function isWorkspaceEditorTextPath(requestedPath: string): boolean {
  const filename = requestedPath.replaceAll("\\", "/").split("/").filter(Boolean).pop() ?? "";
  if (!filename) return false;
  const contentType = getContentType("", filename);
  const normalized = normalizeContentType(contentType);
  return normalized.startsWith("text/") || normalized === "application/json";
}
