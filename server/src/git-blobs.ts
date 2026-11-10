import type { IncomingMessage, ServerResponse } from "node:http";
import { basename, extname } from "node:path";

import {
  browseSizeLimit,
  getContentType,
  MAX_BROWSE_IMAGE_FILE_SIZE,
} from "./file-serving-policy.js";
import { execGit, type GitTrust } from "./git-safe.js";
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
  const bytes = Buffer.isBuffer(stdout) ? stdout : Buffer.from(String(stdout), "latin1");
  if (!error) return { kind: "ok", bytes };
  if (error.code === MAX_BUFFER_EXCEEDED) return { kind: "too-large", prefix: bytes };
  return { kind: "missing" };
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
  const blob = await readGitBlob(trust, cwd, revision, path, maxBytes);
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
