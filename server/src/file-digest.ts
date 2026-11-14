import { createHash } from "node:crypto";
import type { FileHandle } from "node:fs/promises";

/**
 * SHA-256 of a whole served file, so a client can check a download before it
 * offers the file. Computed once per file version, streamed through the
 * already-verified handle (never buffered), and cached by the version key:
 * device, inode, size, and mtime in nanoseconds. A file rewritten in place
 * changes its mtime and so its key.
 */

/** Versions kept; one entry is a key and a 44-character digest. */
const MAX_CACHED_DIGESTS = 512;

const cached = new Map<string, string>();
const computing = new Map<string, Promise<string>>();

/** The cache key, also the strong validator's input, for one file version. */
export function fileVersionKey(version: {
  dev: bigint;
  ino: bigint;
  size: bigint;
  mtimeNs: bigint;
}): string {
  return [version.dev, version.ino, version.size, version.mtimeNs]
    .map((part) => part.toString(16))
    .join("-");
}

/** Base64 SHA-256 of every byte `handle` reads, for the version `key` names. */
export async function fileSha256(handle: FileHandle, key: string): Promise<string> {
  const hit = cached.get(key);
  if (hit !== undefined) {
    // Most recently used goes last; the first entry is evicted first.
    cached.delete(key);
    cached.set(key, hit);
    return hit;
  }
  const running = computing.get(key);
  if (running) return running;
  const promise = (async () => {
    const hash = createHash("sha256");
    // `autoClose: false`: the caller still serves the bytes from this handle.
    for await (const chunk of handle.createReadStream({ start: 0, autoClose: false })) {
      hash.update(chunk as Buffer);
    }
    const digest = hash.digest("base64");
    cached.set(key, digest);
    if (cached.size > MAX_CACHED_DIGESTS) {
      const oldest = cached.keys().next().value;
      if (oldest !== undefined) cached.delete(oldest);
    }
    return digest;
  })();
  computing.set(key, promise);
  try {
    return await promise;
  } finally {
    computing.delete(key);
  }
}
