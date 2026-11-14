import type { IncomingMessage, ServerResponse } from "node:http";
import { constants } from "node:fs";
import { access, open, opendir, realpath, stat, type FileHandle } from "node:fs/promises";
import { basename, dirname, extname, isAbsolute, resolve } from "node:path";
import type { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { constants as zlibConstants, createBrotliCompress, createGzip } from "node:zlib";
import { fileURLToPath } from "node:url";

import { fileSha256, fileVersionKey } from "./file-digest.js";
import { browseSizeLimit, getContentType } from "./file-serving-policy.js";
import { expandHome, isPathWithinRoot } from "./path-utils.js";
import { encodeHostResolvedPathHeader, expandExactHostPath } from "./host-file-path.js";
import { logRejectedByteRange, parseByteRangeHeader } from "./http-range.js";
import { workspaceMountRoot } from "./session-work-root.js";
import type { Workspace } from "./types.js";
import { resolveWorkspaceUserPath } from "./workspace-user-path.js";
import { resolveWorkspaceWorktree } from "./worktrees.js";

/**
 * Current-file reads: origin resolution, servable-file policy, and byte serving.
 *
 * Origin selects how a path resolves; it is not a host-file secrecy check.
 * Pairing/auth is the gate for host origins. Sandbox workspaces stay confined
 * to their mount after realpath so a guest-planted symlink cannot expose host
 * bytes or directory entries.
 */

export interface ServableFile {
  filePath: string;
  size: number;
  contentType: string;
}

export type ServableFileResult =
  | { kind: "ok"; file: ServableFile }
  | { kind: "missing" }
  | { kind: "not-file" }
  | { kind: "unreadable" }
  | { kind: "too-large"; maxSizeMegabytes: number };

/**
 * Stat a realpath and, for a whole read, apply the browse size limit of its
 * detected content type. `typePath` names the file for MIME detection; a
 * symlink such as `clip.mp4 -> blobs/sha256` keeps the requested name's type.
 *
 * The limits guard a reader that holds the whole body in memory (the text
 * viewer, an image decoder). A ranged read streams by construction (a player,
 * a download to disk) and a HEAD has no body, so neither is capped: pass
 * `wholeRead: false` for them.
 */
export async function statServableFile(
  filePath: string,
  typePath = filePath,
  options: { wholeRead: boolean } = { wholeRead: true },
): Promise<ServableFileResult> {
  let fileStat: Awaited<ReturnType<typeof stat>>;
  try {
    fileStat = await stat(filePath);
  } catch {
    return { kind: "missing" };
  }
  if (!fileStat.isFile()) return { kind: "not-file" };
  try {
    await access(filePath, constants.R_OK);
  } catch {
    return { kind: "unreadable" };
  }

  const contentType = getContentType(extname(typePath).toLowerCase(), basename(typePath));
  const maxSize = options.wholeRead ? browseSizeLimit(contentType) : null;
  if (maxSize !== null && fileStat.size > maxSize) {
    return { kind: "too-large", maxSizeMegabytes: Math.round(maxSize / (1024 * 1024)) };
  }
  return { kind: "ok", file: { filePath, size: fileStat.size, contentType } };
}

function sendJsonError(res: ServerResponse, status: number, message: string): number {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: message }));
  return status;
}

/**
 * Open a checked realpath for serving and prove the handle is that file.
 *
 * Confinement checks run on a path, then the bytes come from a later open.
 * A guest that swaps a symlink into that window could redirect the open, so
 * the final component is opened with O_NOFOLLOW and the path must still
 * resolve to itself with the handle's dev/inode after the open.
 */
export async function openVerifiedFile(
  filePath: string,
): Promise<
  | { kind: "ok"; handle: FileHandle; size: number; modifiedMs: number; version: string }
  | { kind: "error"; status: number }
> {
  let handle: FileHandle;
  try {
    handle = await open(filePath, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch (error: unknown) {
    // ELOOP: the checked final component is now a symlink.
    const code = (error as NodeJS.ErrnoException).code;
    return { kind: "error", status: code === "ELOOP" ? 404 : 500 };
  }
  try {
    const opened = await handle.stat({ bigint: true });
    const current =
      (await realpath(filePath)) === filePath ? await stat(filePath, { bigint: true }) : undefined;
    if (
      opened.isFile() &&
      current !== undefined &&
      current.dev === opened.dev &&
      current.ino === opened.ino
    ) {
      return {
        kind: "ok",
        handle,
        size: Number(opened.size),
        modifiedMs: Number(opened.mtimeMs),
        version: fileVersionKey(opened),
      };
    }
  } catch {
    // Fall through: a path that changed or vanished is not the checked file.
  }
  await handle.close();
  return { kind: "error", status: 404 };
}

/** A client that wants the whole file's SHA-256 sends this request header with `sha-256`. */
export const FILE_DIGEST_REQUEST_HEADER = "x-oppi-want-file-digest";
/** `sha-256=:<base64>:` of every byte of the file, whatever the range or coding of the response. */
export const FILE_DIGEST_RESPONSE_HEADER = "X-Oppi-File-Digest";

/** Smallest body worth compressing; below it the headers cost more than they save. */
const MIN_COMPRESSED_BYTES = 1024;

/**
 * Text-like content compresses well. Archives, images, audio, and video are
 * already compressed, and unrecognised bytes (`application/octet-stream`)
 * are not assumed to be text.
 */
function isCompressibleContentType(contentType: string): boolean {
  const type = contentType.split(";", 1)[0]?.trim().toLowerCase() ?? "";
  return (
    type.startsWith("text/") ||
    type === "application/json" ||
    type === "image/svg+xml" ||
    type.endsWith("+json") ||
    type.endsWith("+xml")
  );
}

/** The coding to send for `accept-encoding`: Brotli, then gzip, else none. */
function negotiatedEncoding(acceptEncoding: string | string[] | undefined): "br" | "gzip" | null {
  if (typeof acceptEncoding !== "string") return null;
  const offered = new Map<string, number>();
  for (const part of acceptEncoding.split(",")) {
    const [name, ...params] = part.trim().toLowerCase().split(";");
    const q = params.map((param) => param.trim()).find((param) => param.startsWith("q="));
    offered.set(name.trim(), q ? Number(q.slice(2)) : 1);
  }
  if ((offered.get("br") ?? 0) > 0) return "br";
  if ((offered.get("gzip") ?? 0) > 0) return "gzip";
  return null;
}

function makeCompressor(encoding: "br" | "gzip"): Transform {
  // Fast settings: the file streams as it is read, and Brotli's default
  // quality (11) would make the server, not the link, the bottleneck.
  return encoding === "br"
    ? createBrotliCompress({ params: { [zlibConstants.BROTLI_PARAM_QUALITY]: 5 } })
    : createGzip({ level: 6 });
}

/**
 * Serve GET/HEAD bytes with one single-byte-range policy (200/206/416).
 * Headers are written only after the verified open, so an open failure is a
 * clean 500 and a swapped path a 404 instead of a truncated 200. Returns the
 * response status once the body transfer ends and the handle is closed.
 *
 * Downloads resume from here:
 *
 * - A response to a request that carries `Range` names the file version in a
 *   strong `ETag` (device, inode, size, and mtime in nanoseconds). Only
 *   ranged requests get it: the editor reads without `Range`, and its `ETag`
 *   is the content hash of a tagged read (`sendExactFileBytes`).
 * - `If-Range` with that tag serves the range only while the file is the same
 *   version; any other tag, or a date, serves the whole file as a 200, so a
 *   client restarts instead of splicing two versions.
 * - `X-Oppi-Want-File-Digest: sha-256` adds the whole file's SHA-256
 *   (`file-digest.ts`).
 * - A GET of a whole text-like file is compressed when the client accepts
 *   Brotli or gzip; that includes `Range: bytes=0-`, which a download sends
 *   first and which is then answered as a 200. A range from a later offset,
 *   and everything not text-like, goes uncompressed.
 */
export async function sendFileBytes(
  req: IncomingMessage | undefined,
  res: ServerResponse,
  method: string,
  file: ServableFile,
  options: { rangeLogTag: string; extraHeaders?: Record<string, string> },
): Promise<number> {
  const opened = await openVerifiedFile(file.filePath);
  if (opened.kind === "error") {
    return sendJsonError(
      res,
      opened.status,
      opened.status === 404 ? "File not found" : "Failed to read file",
    );
  }
  const { handle, size } = opened;
  const headersIn = req?.headers ?? {};
  const etag = `"${opened.version}"`;
  const asksForRange = headersIn.range !== undefined;
  const compressible = isCompressibleContentType(file.contentType);
  const commonHeaders: Record<string, string> = {
    "Content-Type": file.contentType,
    "Cache-Control": "private, no-cache",
    "Accept-Ranges": "bytes",
    "Last-Modified": new Date(opened.modifiedMs).toUTCString(),
    ...(asksForRange ? { ETag: etag } : {}),
    ...(compressible ? { Vary: "Accept-Encoding" } : {}),
    ...options.extraHeaders,
  };
  if (headersIn[FILE_DIGEST_REQUEST_HEADER] === "sha-256") {
    try {
      const digest = await fileSha256(handle, opened.version);
      commonHeaders[FILE_DIGEST_RESPONSE_HEADER] = `sha-256=:${digest}:`;
    } catch {
      await handle.close().catch(() => {});
      return sendJsonError(res, 500, "Failed to read file");
    }
  }
  // A stale `If-Range` (another version, or a date) asks for the whole file.
  const ifRange = headersIn["if-range"];
  const rangeHeader = ifRange === undefined || ifRange === etag ? headersIn.range : undefined;
  const range = parseByteRangeHeader(rangeHeader, size);

  if (range.kind === "invalid" || range.kind === "unsatisfiable") {
    await handle.close();
    logRejectedByteRange(options.rangeLogTag, rangeHeader, range.kind, size);
    res.writeHead(416, {
      ...commonHeaders,
      "Content-Range": `bytes */${size}`,
      "Content-Length": "0",
    });
    res.end();
    return 416;
  }

  const requested = range.kind === "valid" ? { start: range.start, end: range.end } : undefined;
  const wholeFile =
    requested === undefined || (requested.start === 0 && requested.end === size - 1);
  const encoding =
    method.toUpperCase() === "GET" && compressible && wholeFile && size >= MIN_COMPRESSED_BYTES
      ? negotiatedEncoding(headersIn["accept-encoding"])
      : null;
  // A compressed whole file answers as a 200: its coded length is not known
  // up front, and a range is a range of the coded bytes.
  const byteRange = encoding ? undefined : requested;
  const status = byteRange ? 206 : 200;
  const headers: Record<string, string> = encoding
    ? { ...commonHeaders, "Content-Encoding": encoding }
    : byteRange
      ? {
          ...commonHeaders,
          "Content-Range": `bytes ${byteRange.start}-${byteRange.end}/${size}`,
          "Content-Length": (byteRange.end - byteRange.start + 1).toString(),
        }
      : { ...commonHeaders, "Content-Length": size.toString() };

  if (method.toUpperCase() === "HEAD") {
    await handle.close();
    res.writeHead(status, headers);
    res.end();
    return status;
  }

  // An empty file has no readable range; createReadStream on a handle still
  // ends cleanly. A client abort (players cancel most Range GETs) must still
  // close the handle: `pipe` only unpipes on abort, leaving the handle for GC,
  // and Node's DEP0137 GC close crashes the server. `pipeline` destroys the
  // source on abort, and the explicit close covers every path. Headers are
  // already sent, so failures here are contained: no 500 body, no rejection
  // escaping to the void'd HTTP handler.
  // `start` always: the digest read may have run first through this handle.
  const stream = handle.createReadStream(byteRange ?? { start: 0 });
  res.writeHead(status, headers);
  try {
    if (encoding) {
      await pipeline(stream, makeCompressor(encoding), res);
    } else {
      await pipeline(stream, res);
    }
  } catch {
    if (!res.destroyed) res.destroy();
  } finally {
    await handle.close().catch(() => {});
  }
  return status;
}

/**
 * Send already-read bytes. Used when an ETag must hash the exact body that
 * goes on the wire, so a later open cannot observe a different file.
 */
export function sendExactFileBytes(
  res: ServerResponse,
  method: string,
  file: { bytes: Buffer; contentType: string },
  extraHeaders?: Record<string, string>,
): number {
  const headers: Record<string, string> = {
    "Content-Type": file.contentType,
    "Cache-Control": "private, no-cache",
    "Accept-Ranges": "bytes",
    "Content-Length": file.bytes.length.toString(),
    ...extraHeaders,
  };
  if (method.toUpperCase() === "HEAD") {
    res.writeHead(200, headers);
    res.end();
    return 200;
  }
  res.writeHead(200, headers);
  res.end(file.bytes);
  return 200;
}

/** `X-Oppi-Resolved-Path` for a host realpath. Never send it for sandbox files. */
export function resolvedPathHeaders(file: ResolvedCurrentFile): Record<string, string> {
  return file.confinedRoot
    ? {}
    : { "X-Oppi-Resolved-Path": encodeHostResolvedPathHeader(file.realPath) };
}

/**
 * Root for a workspace browse/read request. Sandbox requests always use the
 * SDK mount, regardless of a client-supplied worktree id. Host workspaces
 * resolve requested worktrees; an unknown id must not fall through to home.
 */
export async function resolveWorkspaceFileRoot(
  workspace: Workspace,
  worktreeId: string | undefined,
  dataDir: string,
): Promise<string | null> {
  const requested = worktreeId?.trim();
  if (workspace.runtime === "sandbox" || !requested) {
    return workspaceMountRoot(workspace, { create: true });
  }
  return (await resolveWorkspaceWorktree(workspace, requested, { dataDir }))?.path ?? null;
}

export interface ResolvedCurrentFile {
  /** Canonical path after symlink resolution. */
  realPath: string;
  /** Mapped path before symlink resolution; sidecars live beside this name. */
  lexicalPath: string;
  /** Sandbox mount realpath. Every read or listing must stay inside it. */
  confinedRoot?: string;
}

export type CurrentFileOrigin =
  /** Absolute, `~`, and local `file://` paths; relative paths need `cwd`. */
  | { kind: "host"; cwd?: () => string | null; homeDir?: string }
  /** Workspace or workspace-session root: worktree, host mount, or sandbox mount. */
  | { kind: "workspace"; workspace: Workspace; root: string }
  /** An editable Skill's directory; only Skill-relative paths inside it resolve. */
  | { kind: "skill"; root: string }
  /** Pi's agent directory; only the allowlisted agent-relative paths resolve. */
  | { kind: "pi"; agentDir: string };

export type CurrentFilePathResult =
  | { kind: "ok"; file: ResolvedCurrentFile }
  | { kind: "not-found" }
  | { kind: "root-not-found" }
  | { kind: "outside-sandbox" };

export async function resolveCurrentFilePath(
  origin: CurrentFileOrigin,
  requestedPath: string,
): Promise<CurrentFilePathResult> {
  if (origin.kind === "host") {
    const lexicalPath = resolveHostOriginPath(origin, requestedPath);
    if (!lexicalPath) return { kind: "not-found" };
    try {
      return { kind: "ok", file: { realPath: await realpath(lexicalPath), lexicalPath } };
    } catch {
      return { kind: "not-found" };
    }
  }

  let realRoot: string;
  try {
    realRoot = await realpath(origin.kind === "pi" ? origin.agentDir : origin.root);
  } catch {
    return { kind: "root-not-found" };
  }
  if (origin.kind === "skill" || origin.kind === "pi") {
    const root = resolve(origin.kind === "skill" ? origin.root : origin.agentDir);
    const lexicalPath = isAbsolute(requestedPath) ? null : resolve(root, requestedPath);
    if (!lexicalPath || lexicalPath === root || !isPathWithinRoot(lexicalPath, root)) {
      return { kind: "not-found" };
    }
    try {
      return { kind: "ok", file: { realPath: await realpath(lexicalPath), lexicalPath } };
    } catch {
      return { kind: "not-found" };
    }
  }
  const sandboxed = origin.workspace.runtime === "sandbox";
  const lexicalPath =
    resolveWorkspaceUserPath({
      workspace: origin.workspace,
      requestedPath,
      root: origin.root,
    }) ?? (sandboxed ? null : resolveHostWorkspacePath(requestedPath, realRoot));
  if (!lexicalPath) return sandboxed ? { kind: "outside-sandbox" } : { kind: "not-found" };

  let realPath: string;
  try {
    realPath = await realpath(lexicalPath);
  } catch {
    return { kind: "not-found" };
  }
  if (sandboxed && !isPathWithinRoot(realPath, realRoot)) return { kind: "outside-sandbox" };
  return {
    kind: "ok",
    file: { realPath, lexicalPath, ...(sandboxed ? { confinedRoot: realRoot } : {}) },
  };
}

function resolveHostOriginPath(
  origin: Extract<CurrentFileOrigin, { kind: "host" }>,
  requestedPath: string,
): string | null {
  const exact = expandExactHostPath(requestedPath, { homeDir: origin.homeDir });
  if (exact) return exact;
  if (!origin.cwd || !requestedPath || requestedPath.includes("\0")) return null;
  if (requestedPath.startsWith("~") || requestedPath.toLowerCase().startsWith("file:")) {
    return null;
  }
  const cwd = origin.cwd();
  return cwd ? resolve(cwd, requestedPath) : null;
}

/** Host workspaces: auth is the gate, so absolute, `~`, and `..` paths resolve. */
function resolveHostWorkspacePath(requestedPath: string, workspaceRoot: string): string | null {
  if (requestedPath.includes("\0")) return null;
  if (requestedPath.toLowerCase().startsWith("file:")) {
    try {
      const url = new URL(requestedPath);
      return url.protocol === "file:" ? fileURLToPath(url) : null;
    } catch {
      return null;
    }
  }
  const expanded = expandHome(requestedPath);
  return isAbsolute(expanded) ? resolve(expanded) : resolve(workspaceRoot, expanded);
}

const TIMED_TEXT_EXTENSIONS = "vtt|srt|ass|ssa|lrc";
const MAX_SIDECAR_SCAN_ENTRIES = 10_000;
const MAX_SIDECARS = 32;

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Same-stem timed-text sidecars beside an existing media file:
 * `stem(.lang)?.(vtt|srt|ass|ssa|lrc)`. This is not a directory listing: only
 * matching regular-file names are returned, the scan is bounded, and sandbox
 * sidecars must stay inside the mount after realpath. Like directory listings,
 * the scan reads by path, so a racing parent-directory swap can expose names
 * (never bytes: the sidecar fetch goes through the verified read).
 */
export async function listTimedTextSidecars(
  media: ResolvedCurrentFile,
): Promise<{ names: string[]; truncated: boolean }> {
  const stem = basename(media.lexicalPath, extname(media.lexicalPath));
  if (!stem) return { names: [], truncated: false };
  const pattern = new RegExp(
    `^${escapeRegExp(stem)}(?:\\.[A-Za-z][A-Za-z0-9-]*)?\\.(?:${TIMED_TEXT_EXTENSIONS})$`,
    "i",
  );

  let directoryPath: string;
  try {
    directoryPath = await realpath(dirname(media.lexicalPath));
  } catch {
    return { names: [], truncated: false };
  }
  if (media.confinedRoot && !isPathWithinRoot(directoryPath, media.confinedRoot)) {
    return { names: [], truncated: false };
  }

  const matches: string[] = [];
  let truncated = false;
  let scanned = 0;
  let directory: Awaited<ReturnType<typeof opendir>>;
  try {
    directory = await opendir(directoryPath);
  } catch {
    return { names: [], truncated: false };
  }
  try {
    for await (const entry of directory) {
      if (scanned >= MAX_SIDECAR_SCAN_ENTRIES || matches.length >= MAX_SIDECARS) {
        truncated = true;
        break;
      }
      scanned += 1;
      if (pattern.test(entry.name)) matches.push(entry.name);
    }
  } catch {
    return { names: [], truncated: false };
  }

  const names: string[] = [];
  for (const name of matches) {
    const candidate = `${directoryPath}/${name}`;
    try {
      const real = await realpath(candidate);
      if (media.confinedRoot && !isPathWithinRoot(real, media.confinedRoot)) continue;
      if (!(await stat(real)).isFile()) continue;
      names.push(name);
    } catch {
      continue;
    }
  }
  names.sort();
  return { names, truncated };
}
