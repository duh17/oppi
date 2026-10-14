import type { FileHandle } from "node:fs/promises";

import { parseFromTokenizer } from "music-metadata";
import { FileTokenizer, type IReadChunkOptions } from "strtok3";

import { openVerifiedFile } from "./current-file.js";

/**
 * Audio length from file headers, so a compact player can label a clip before
 * playback without the client downloading audio bytes.
 *
 * Most formats carry the length in a header (WAV/AIFF/CAF chunks, MP4 `mvhd`,
 * FLAC STREAMINFO, MP3 Xing/Info). MP3 without a Xing frame and Ogg need a
 * scan, bounded by `PARSE_DEADLINE_MS`. Results, including "unknown", are
 * cached per file version so a scan runs once.
 */
export interface MediaInfo {
  durationSeconds?: number;
}

const PARSE_DEADLINE_MS = 5_000;
/** A single tag payload (lyrics, chapters) above this fails the parse. */
const MAX_METADATA_PAYLOAD_BYTES = 4 * 1024 * 1024;
const MAX_CACHE_ENTRIES = 256;

const cache = new Map<string, Promise<MediaInfo>>();

/**
 * Reads through the handle `openVerifiedFile` proves is the checked path, so a
 * symlink swapped in after the confinement check cannot redirect the parse.
 * Returns null when that open fails (the file changed or vanished).
 */
export async function readAudioMediaInfo(
  realPath: string,
  mimeType: string,
): Promise<MediaInfo | null> {
  const opened = await openVerifiedFile(realPath);
  if (opened.kind === "error") return null;
  const { handle, size } = opened;
  let key: string;
  try {
    const info = await handle.stat();
    key = `${info.dev}:${info.ino}:${info.size}:${info.mtimeMs}`;
  } catch {
    await handle.close();
    return null;
  }
  const cached = cache.get(key);
  if (cached) {
    await handle.close();
    return cached;
  }
  const parsed = parseDuration(handle, size, mimeType);
  cache.set(key, parsed);
  if (cache.size > MAX_CACHE_ENTRIES) {
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  return parsed;
}

async function parseDuration(
  handle: FileHandle,
  size: number,
  mimeType: string,
): Promise<MediaInfo> {
  const tokenizer = new DeadlineFileTokenizer(
    handle,
    size,
    mimeType,
    AbortSignal.timeout(PARSE_DEADLINE_MS),
  );
  try {
    const metadata = await parseFromTokenizer(tokenizer, {
      duration: true,
      skipCovers: true,
      maxMemoryAllocation: MAX_METADATA_PAYLOAD_BYTES,
    });
    const duration = metadata.format.duration;
    return typeof duration === "number" && Number.isFinite(duration) && duration >= 0
      ? { durationSeconds: duration }
      : {};
  } catch {
    // Unknown, truncated, or over-deadline audio has no label, not an error:
    // the client keeps its playback controls and learns the length on play.
    return {};
  } finally {
    await tokenizer.close().catch(() => {});
  }
}

/**
 * strtok3's file tokenizer ignores abort signals, so the deadline is checked
 * on every read. The constructor is protected; this subclass is how a caller
 * hands it an already-verified handle instead of a path to reopen.
 */
class DeadlineFileTokenizer extends FileTokenizer {
  private readonly deadline: AbortSignal;

  constructor(handle: FileHandle, size: number, mimeType: string, deadline: AbortSignal) {
    super(handle, { fileInfo: { size, mimeType } });
    this.deadline = deadline;
  }

  override readBuffer(buffer: Uint8Array, options?: IReadChunkOptions): Promise<number> {
    this.deadline.throwIfAborted();
    return super.readBuffer(buffer, options);
  }

  override peekBuffer(buffer: Uint8Array, options?: IReadChunkOptions): Promise<number> {
    this.deadline.throwIfAborted();
    return super.peekBuffer(buffer, options);
  }
}
