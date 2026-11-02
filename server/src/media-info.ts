import type { FileHandle } from "node:fs/promises";

import { readAudioDuration } from "./audio-duration.js";
import { openVerifiedFile } from "./current-file.js";

/**
 * Audio length from file headers, so a compact player can label a clip before
 * playback without the client downloading audio bytes.
 *
 * `audio-duration.ts` reads WAV/RF64, MP3, MP4/M4A and FLAC headers with
 * bounded reads; other formats have no label. Results, including "unknown",
 * are cached per file version so a file is parsed once.
 */
export interface MediaInfo {
  durationSeconds?: number;
}

const PARSE_DEADLINE_MS = 5_000;
const MAX_CACHE_ENTRIES = 256;
const cache = new Map<string, Promise<MediaInfo>>();

/**
 * Reads through the handle `openVerifiedFile` proves is the checked path, so a
 * symlink swapped in after the confinement check cannot redirect the parse.
 * An open failure keeps `openVerifiedFile`'s status: 404 for a swapped or
 * vanished path, 500 when the server cannot read the file.
 */
export async function readAudioMediaInfo(
  realPath: string,
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
    parsed = parseDuration(handle, size);
    cache.set(key, parsed);
    if (cache.size > MAX_CACHE_ENTRIES) {
      const oldest = cache.keys().next().value;
      if (oldest !== undefined) cache.delete(oldest);
    }
  }
  return { kind: "ok", info: await parsed };
}

async function parseDuration(handle: FileHandle, size: number): Promise<MediaInfo> {
  try {
    // Unknown, truncated, or over-deadline audio has no label, not an error:
    // the client keeps its playback controls and learns the length on play.
    const duration = await readAudioDuration(
      {
        size,
        read: async (buffer, position) =>
          (await handle.read(buffer, 0, buffer.length, position)).bytesRead,
      },
      AbortSignal.timeout(PARSE_DEADLINE_MS),
    );
    return duration === undefined ? {} : { durationSeconds: duration };
  } finally {
    await handle.close().catch(() => {});
  }
}
