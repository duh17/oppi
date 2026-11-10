import type { IncomingMessage, ServerResponse } from "node:http";
import { basename, extname } from "node:path";

import {
  browseSizeLimit,
  getContentType,
  MAX_BROWSE_IMAGE_FILE_SIZE,
} from "./file-serving-policy.js";
import { execGit, SandboxGitRefusedError, type GitTrust } from "./git-safe.js";
import { logRejectedByteRange, parseByteRangeHeader } from "./http-range.js";
import { HttpStatusError } from "./http-status-error.js";
import { expandHome } from "./path-utils.js";

/**
 * File bytes as Git stores them at a revision, for a diff of a file that has no
 * text diff: the client shows the file itself, from the commit's blob and not
 * the working tree.
 */

const GIT_TIMEOUT_MS = 5000;
const MAX_BUFFER_EXCEEDED = "ERR_CHILD_PROCESS_STDIO_MAXBUFFER";

/**
 * Blobs of an immutable revision, kept briefly so the byte ranges of one
 * playback (AVPlayer asks for many) read Git once. Bounded by entries, total
 * bytes, and age.
 */
const CACHE_MAX_ENTRIES = 4;
const CACHE_MAX_BYTES = 128 * 1024 * 1024;
const CACHE_TTL_MS = 120_000;
const blobCache = new Map<string, { bytes: Buffer; at: number }>();

/** `HEAD`, a commit hash, or the first parent of either. */
const BLOB_REVISION = /^(?:HEAD|[0-9a-f]{4,64})\^?$/i;

export class GitBlobError extends HttpStatusError {}

export type GitBlobRead =
  | { kind: "ok"; bytes: Buffer }
  | { kind: "missing" }
  /** Past `maxBytes`; `prefix` holds the first bytes read. */
  | { kind: "too-large"; prefix: Buffer };

/** Whether `bytes` looks like binary data: it holds a NUL byte. */
export function bytesLookBinary(bytes: Buffer): boolean {
  return bytes.includes(0);
}

/**
 * A Git failure that means "no such revision or path" is a miss. Anything else
 * (a timeout, git not starting, the sandbox refusing the command) is a server
 * error, not a missing file.
 */
function throwUnlessMissing(error: Error & { code?: unknown; killed?: unknown }): void {
  const exited = typeof error.code === "number" && error.killed !== true;
  if (error instanceof SandboxGitRefusedError || !exited) {
    throw new GitBlobError(500, "Failed to read the file from Git.");
  }
}

/**
 * Read `<revision>:<path>`. `show` is the one subcommand that reads a blob for
 * both host and sandbox trust.
 */
export async function readGitBlob(
  trust: GitTrust,
  cwd: string,
  revision: string,
  path: string,
  maxBytes: number,
): Promise<GitBlobRead> {
  const { error, stdout } = await execGit(trust, expandHome(cwd), ["show", `${revision}:${path}`], {
    timeout: GIT_TIMEOUT_MS,
    maxBuffer: maxBytes,
    encoding: "buffer",
  });
  // `encoding: "buffer"` makes stdout a Buffer; a refused command has none and fails below.
  const bytes = stdout as Buffer;
  if (!error) return { kind: "ok", bytes };
  if (error.code === MAX_BUFFER_EXCEEDED) return { kind: "too-large", prefix: bytes };
  throwUnlessMissing(error);
  return { kind: "missing" };
}

/** The commit a revision names now, so a moving `HEAD` can key the cache; null when it names none. */
async function pinRevision(trust: GitTrust, cwd: string, revision: string): Promise<string | null> {
  if (!/^HEAD/i.test(revision)) return revision;
  const { error, stdout } = await execGit(
    trust,
    expandHome(cwd),
    ["rev-parse", "--verify", "--quiet", `${revision}^{commit}`],
    { timeout: GIT_TIMEOUT_MS },
  );
  if (error) {
    throwUnlessMissing(error);
    return null;
  }
  return String(stdout).trim();
}

async function readCachedGitBlob(
  trust: GitTrust,
  cwd: string,
  revision: string,
  path: string,
  maxBytes: number,
): Promise<GitBlobRead> {
  const pinned = await pinRevision(trust, cwd, revision);
  if (pinned === null) return { kind: "missing" };
  const key = `${cwd}\0${pinned}\0${path}`;
  const hit = blobCache.get(key);
  if (hit && Date.now() - hit.at < CACHE_TTL_MS) {
    blobCache.delete(key);
    blobCache.set(key, hit); // most recently used last
    return { kind: "ok", bytes: hit.bytes };
  }
  blobCache.delete(key);
  const blob = await readGitBlob(trust, cwd, pinned, path, maxBytes);
  if (blob.kind === "ok" && blob.bytes.length <= CACHE_MAX_BYTES) {
    blobCache.set(key, { bytes: blob.bytes, at: Date.now() });
    let total = 0;
    for (const entry of blobCache.values()) total += entry.bytes.length;
    for (const [oldKey, entry] of blobCache) {
      if (blobCache.size <= CACHE_MAX_ENTRIES && total <= CACHE_MAX_BYTES) break;
      blobCache.delete(oldKey);
      total -= entry.bytes.length;
    }
  }
  return blob;
}

/** Serve one blob (GET/HEAD, one byte range) with the browse size limit for its type. */
export async function serveGitBlob(
  req: IncomingMessage,
  res: ServerResponse,
  args: { trust: GitTrust; cwd: string; revision: string; path: string },
): Promise<void> {
  const { trust, cwd, revision, path } = args;
  if (!BLOB_REVISION.test(revision)) throw new GitBlobError(400, "rev parameter invalid");
  if (path.trim().length === 0) throw new GitBlobError(400, "path parameter required");
  if (path.includes("\0")) throw new GitBlobError(400, "path parameter invalid");

  const contentType = getContentType(extname(path).toLowerCase(), basename(path));
  // A blob is buffered to answer, so streaming media gets the largest cap, not none.
  const maxBytes = browseSizeLimit(contentType) ?? MAX_BROWSE_IMAGE_FILE_SIZE;
  const blob = await readCachedGitBlob(trust, cwd, revision, path, maxBytes);
  if (blob.kind === "missing") throw new GitBlobError(404, "File not found at revision");
  if (blob.kind === "too-large") {
    const megabytes = Math.round(maxBytes / (1024 * 1024));
    throw new GitBlobError(413, `File too large to preview (max ${megabytes} MB).`);
  }

  const { bytes } = blob;
  const headers: Record<string, string> = {
    "Content-Type": contentType,
    "Cache-Control": "private, no-cache",
    "Accept-Ranges": "bytes",
  };
  const rangeHeader = req.headers.range;
  const range = parseByteRangeHeader(rangeHeader, bytes.length);
  if (range.kind === "invalid" || range.kind === "unsatisfiable") {
    logRejectedByteRange("git_blob", rangeHeader, range.kind, bytes.length);
    res.writeHead(416, {
      ...headers,
      "Content-Range": `bytes */${bytes.length}`,
      "Content-Length": "0",
    });
    res.end();
    return;
  }
  const slice = range.kind === "valid" ? bytes.subarray(range.start, range.end + 1) : bytes;
  res.writeHead(range.kind === "valid" ? 206 : 200, {
    ...headers,
    ...(range.kind === "valid"
      ? { "Content-Range": `bytes ${range.start}-${range.end}/${bytes.length}` }
      : {}),
    "Content-Length": slice.length.toString(),
  });
  res.end(req.method?.toUpperCase() === "HEAD" ? undefined : slice);
}
