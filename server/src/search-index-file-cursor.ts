/**
 * Byte cursors for file-backed search rows: what identifies the indexed prefix of a session
 * file, whether the file still extends it, and how an appended tail merges onto the row.
 */

import { createHash } from "node:crypto";
import { closeSync, openSync, readSync, statSync } from "node:fs";
import { open, stat } from "node:fs/promises";

import {
  extractSearchTranscriptAddition,
  hasUnsafeSearchToolName,
  mergeSearchTranscript,
  type SearchTranscriptContent,
} from "./search-transcript.js";
import { parseSessionEntries, sessionTranscriptLeafId, type SessionEntry } from "./trace.js";

/** Byte cursor stored on fts_meta so the next turn reads only the append. */
export interface FileCursor {
  dev: string;
  ino: string;
  offset: number;
  boundary: string;
  leafId: string;
}

export interface FileStat {
  dev: string;
  ino: string;
  size: number;
  mtimeMs: number;
}

export interface FtsMetaRow {
  jsonl_path: string | null;
  jsonl_mtime_ms: number;
  jsonl_size: number;
  workspace_id: string | null;
  title: string | null;
  durable_marker: string | null;
  jsonl_dev: string | null;
  jsonl_ino: string | null;
  jsonl_offset: number | null;
  jsonl_boundary: string | null;
  jsonl_leaf_id: string | null;
}

/** Last bytes of the indexed prefix. In-place rewrite keeps the inode, so size and inode alone do not prove the prefix is unchanged. */
const FILE_BOUNDARY_BYTES = 64;
/** Appended entry types that change which earlier lines are on the indexed branch. */
const FULL_REINDEX_ENTRY_TYPES = new Set(["branch_summary", "session"]);

export function fileStatFrom(st: {
  dev: bigint;
  ino: bigint;
  size: bigint;
  mtimeMs: bigint;
}): FileStat | null {
  if (st.size > BigInt(Number.MAX_SAFE_INTEGER)) return null;
  return {
    dev: st.dev.toString(),
    ino: st.ino.toString(),
    size: Number(st.size),
    mtimeMs: Number(st.mtimeMs),
  };
}

export function statFileSync(path: string): FileStat | null {
  try {
    return fileStatFrom(statSync(path, { bigint: true }));
  } catch {
    return null;
  }
}

export async function statFile(path: string): Promise<FileStat | null> {
  try {
    return fileStatFrom(await stat(path, { bigint: true }));
  } catch {
    return null;
  }
}

/** An empty window is the boundary at offset 0. */
function boundaryHash(bytes: Buffer): string {
  return bytes.length === 0 ? "" : createHash("sha256").update(bytes).digest("hex");
}

/** The bytes that identify a cursor: the boundary window ending at `offset`. */
export function readCursorWindowSync(path: string, offset: number): Buffer {
  return readByteRangeSync(path, Math.max(0, offset - FILE_BOUNDARY_BYTES), offset);
}

export async function readCursorWindow(path: string, offset: number): Promise<Buffer> {
  return readByteRange(path, Math.max(0, offset - FILE_BOUNDARY_BYTES), offset);
}

export function readBoundarySync(path: string, offset: number): string {
  return boundaryHash(readCursorWindowSync(path, offset));
}

export async function readBoundary(path: string, offset: number): Promise<string> {
  return boundaryHash(await readCursorWindow(path, offset));
}

/**
 * Does a stored cursor still describe the file? `window` is the boundary
 * window at `stored.offset`. "same": nothing was appended. "grew": the stored
 * prefix is intact and ends on a line, so the tail merges. Everything else is
 * "stale" and needs a full read. "same" ignores the line boundary because
 * there is no tail to split.
 */
export type CursorState = "stale" | "same" | "grew";

export function classifyCursor(stored: FileCursor, st: FileStat, window: Buffer): CursorState {
  if (st.dev !== stored.dev || st.ino !== stored.ino || st.size < stored.offset) return "stale";
  if (boundaryHash(window) !== stored.boundary) return "stale";
  if (st.size === stored.offset) return "same";
  return stored.offset === 0 || window[window.length - 1] === 0x0a ? "grew" : "stale";
}

export function readByteRangeSync(path: string, start: number, end: number): Buffer {
  const length = end - start;
  if (length <= 0) return Buffer.alloc(0);
  const buffer = Buffer.alloc(length);
  const fd = openSync(path, "r");
  try {
    let offset = 0;
    while (offset < length) {
      const bytesRead = readSync(fd, buffer, offset, length - offset, start + offset);
      if (bytesRead === 0) break;
      offset += bytesRead;
    }
    return offset === length ? buffer : buffer.subarray(0, offset);
  } finally {
    closeSync(fd);
  }
}

/**
 * Leaf id from the end of the file. Used to backfill a cursor without reading
 * a session that is already indexed and unchanged.
 */
export function leafIdFromFileTail(path: string, size: number): string {
  if (size <= 0) return "";
  let window = 64 * 1024;
  while (window < size) {
    const start = size - window;
    const text = readByteRangeSync(path, start, size).toString("utf8");
    const newline = text.indexOf("\n");
    if (newline >= 0) {
      const leaf = sessionTranscriptLeafId(parseSessionEntries(text.slice(newline + 1)));
      if (leaf) return leaf;
    }
    window *= 4;
  }
  return (
    sessionTranscriptLeafId(
      parseSessionEntries(readByteRangeSync(path, 0, size).toString("utf8")),
    ) ?? ""
  );
}

export async function readByteRange(path: string, start: number, end: number): Promise<Buffer> {
  const length = end - start;
  if (length <= 0) return Buffer.alloc(0);
  const handle = await open(path, "r");
  try {
    const buffer = Buffer.alloc(length);
    let offset = 0;
    while (offset < length) {
      const { bytesRead } = await handle.read(buffer, offset, length - offset, start + offset);
      if (bytesRead === 0) break;
      offset += bytesRead;
    }
    return offset === length ? buffer : buffer.subarray(0, offset);
  } finally {
    await handle.close();
  }
}

export function cursorFromMeta(meta: FtsMetaRow): FileCursor | null {
  const dev = meta.jsonl_dev;
  const ino = meta.jsonl_ino;
  const offset = meta.jsonl_offset;
  const boundary = meta.jsonl_boundary;
  const leafId = meta.jsonl_leaf_id;
  if (dev === null || ino === null || offset === null || boundary === null || leafId === null) {
    return null;
  }
  return {
    dev,
    ino,
    offset,
    boundary,
    leafId,
  };
}

export function cursorForFile(stat: FileStat, boundary: string, leafId: string | null): FileCursor {
  return {
    dev: stat.dev,
    ino: stat.ino,
    offset: stat.size,
    boundary,
    leafId: leafId ?? "",
  };
}

/**
 * A snapshot must not overwrite a cursor that already indexed a later prefix of
 * the same file. Truncation and a same-size rewrite make the stored cursor
 * stale: the snapshot is the file, and refusing it would retry forever.
 */
export function storedCursorIsNewer(
  stored: FileCursor,
  snapshot: FileCursor,
  fileSize: number,
): boolean {
  if (stored.dev !== snapshot.dev || stored.ino !== snapshot.ino) return false;
  if (snapshot.offset === fileSize && fileSize <= stored.offset) return false;
  if (stored.offset > snapshot.offset) return true;
  return stored.offset === snapshot.offset && stored.boundary !== snapshot.boundary;
}

/**
 * True when the appended entries only extend the indexed leaf. A new session
 * header, a branch summary, or a fork (parent chain misses the stored leaf)
 * changes which earlier lines are on the branch, so the caller must reindex.
 */
function tailExtendsIndexedLeaf(entries: SessionEntry[], leafId: string): boolean {
  if (!leafId || hasUnsafeSearchToolName(entries)) return false;
  for (const entry of entries) {
    if (FULL_REINDEX_ENTRY_TYPES.has(entry.type)) return false;
  }
  const leaf = sessionTranscriptLeafId(entries);
  if (!leaf) return true;
  const byId = new Map<string, SessionEntry>();
  for (const entry of entries) {
    if (entry.id) byId.set(entry.id, entry);
  }
  const seen = new Set<string>();
  let current: SessionEntry | undefined = byId.get(leaf);
  while (current) {
    if (!current.id || seen.has(current.id)) return false;
    seen.add(current.id);
    if (current.parentId === leafId) return true;
    if (!current.parentId) return false;
    current = byId.get(current.parentId);
  }
  return false;
}

export function mergeTail(
  existing: SearchTranscriptContent,
  tailText: string,
  storedLeafId: string,
): { content: SearchTranscriptContent; leafId: string } | null {
  const entries = parseSessionEntries(tailText);
  if (!tailExtendsIndexedLeaf(entries, storedLeafId)) return null;
  return {
    content: mergeSearchTranscript(existing, extractSearchTranscriptAddition(entries)),
    leafId: sessionTranscriptLeafId(entries) ?? storedLeafId,
  };
}
