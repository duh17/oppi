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
/**
 * Total bytes one parse may read. The parser keeps metadata chunks (WAV
 * `LIST`, AIFF `ANNO`) in memory until it finishes, so the per-chunk limit
 * alone lets a crafted file of many chunks exhaust the heap. 8 MiB is far above
 * any real header scan and a small fraction of the heap; a file needing more
 * (long Ogg, header-less VBR MP3) gets no label.
 */
const MAX_PARSE_READ_BYTES = 8 * 1024 * 1024;
const MAX_CACHE_ENTRIES = 256;
/**
 * About 115 days. A crafted Ogg/MP4 header (sample rate or timescale 1, huge
 * granule or duration) parses to ~2^63 s; that is not audio, so it gets no label.
 */
const MAX_DURATION_SECONDS = 10_000_000;

const cache = new Map<string, Promise<MediaInfo>>();

/**
 * Reads through the handle `openVerifiedFile` proves is the checked path, so a
 * symlink swapped in after the confinement check cannot redirect the parse.
 * An open failure keeps `openVerifiedFile`'s status: 404 for a swapped or
 * vanished path, 500 when the server cannot read the file.
 */
export async function readAudioMediaInfo(
  realPath: string,
  mimeType: string,
): Promise<{ kind: "ok"; info: MediaInfo } | { kind: "error"; status: number }> {
  const opened = await openVerifiedFile(realPath);
  if (opened.kind === "error") return opened;
  const { handle, size } = opened;
  let key: string;
  try {
    const info = await handle.stat();
    key = `${info.dev}:${info.ino}:${info.size}:${info.mtimeMs}`;
  } catch {
    await handle.close();
    return { kind: "error", status: 500 };
  }
  let parsed = cache.get(key);
  if (parsed) {
    await handle.close();
  } else {
    parsed = parseDuration(handle, size, mimeType);
    cache.set(key, parsed);
    if (cache.size > MAX_CACHE_ENTRIES) {
      const oldest = cache.keys().next().value;
      if (oldest !== undefined) cache.delete(oldest);
    }
  }
  return { kind: "ok", info: await parsed };
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
    return typeof duration === "number" && duration >= 0 && duration <= MAX_DURATION_SECONDS
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
 * on every read, together with the total-bytes budget. The constructor is
 * protected; this subclass is how a caller hands it an already-verified handle
 * instead of a path to reopen.
 */
class DeadlineFileTokenizer extends FileTokenizer {
  private readonly deadline: AbortSignal;
  private budgetLeft = MAX_PARSE_READ_BYTES;

  constructor(handle: FileHandle, size: number, mimeType: string, deadline: AbortSignal) {
    super(handle, { fileInfo: { size, mimeType } });
    this.deadline = deadline;
  }

  private charge(buffer: Uint8Array, options?: IReadChunkOptions): void {
    this.deadline.throwIfAborted();
    this.budgetLeft -= options?.length ?? buffer.length;
    if (this.budgetLeft < 0) throw new Error("audio parse exceeded its read budget");
  }

  override readBuffer(buffer: Uint8Array, options?: IReadChunkOptions): Promise<number> {
    this.charge(buffer, options);
    return super.readBuffer(buffer, options);
  }

  override peekBuffer(buffer: Uint8Array, options?: IReadChunkOptions): Promise<number> {
    this.charge(buffer, options);
    return super.peekBuffer(buffer, options);
  }
}
