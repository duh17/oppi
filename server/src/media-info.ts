import type { FileHandle } from "node:fs/promises";

import { readAudioHeaders } from "./audio-duration.js";
import { readAudioTags } from "./audio-tags.js";
import { openVerifiedFile } from "./current-file.js";
import type { MediaInfo } from "./types/workspace-files.js";

/**
 * Audio metadata from file headers, so a compact player can label a clip before
 * playback without the client downloading audio bytes.
 *
 * Two bounded passes read the same file: `audio-duration.ts` for the length and
 * format, `audio-tags.ts` for title, artist and album. Each pass has its own
 * 512 KiB budget, so a malformed tag section never costs the length. Formats
 * with no parser here have no label. Results, including "unknown", are cached
 * per file version so a file is parsed once.
 */

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
    parsed = parseMediaInfo(handle, size);
    cache.set(key, parsed);
    if (cache.size > MAX_CACHE_ENTRIES) {
      const oldest = cache.keys().next().value;
      if (oldest !== undefined) cache.delete(oldest);
    }
  }
  return { kind: "ok", info: await parsed };
}

async function parseMediaInfo(handle: FileHandle, size: number): Promise<MediaInfo> {
  try {
    const source = {
      size,
      read: async (buffer: Uint8Array, position: number) =>
        (await handle.read(buffer, 0, buffer.length, position)).bytesRead,
    };
    // Unknown, truncated, or over-deadline audio has no label, not an error:
    // the client keeps its playback controls and learns the length on play.
    const deadline = AbortSignal.timeout(PARSE_DEADLINE_MS);
    const headers = await readAudioHeaders(source, deadline);
    const tags = await readAudioTags(source, deadline);
    const info: MediaInfo = {};
    if (headers.durationSeconds !== undefined) info.durationSeconds = headers.durationSeconds;
    if (headers.format) info.format = headers.format;
    if (tags) info.tags = tags;
    return info;
  } finally {
    await handle.close().catch(() => {});
  }
}
