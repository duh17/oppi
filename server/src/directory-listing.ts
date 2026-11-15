import type { Dirent, Stats } from "node:fs";
import { readdir, realpath, stat } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";

import { compareDirEntryNames } from "./dir-order.js";
import { isPathWithinRoot } from "./path-utils.js";
import type { DirectoryListingResponse, FileEntry } from "./types.js";

/** Entries in one page of a listing; `next` names where the following page starts. */
export const DIRECTORY_PAGE_SIZE = 1000;
/** Entries statted at once: enough to keep the disk busy, few enough to bound open handles. */
const STAT_BATCH = 64;

export interface ContainedPathOptions {
  /** Sandbox mounts: the realpath must also stay inside the root's realpath. */
  confineSymlinks?: boolean;
}

/** Where a requested path landed: a real path, outside the root, or nowhere. */
export type ContainedPathResult =
  { kind: "ok"; path: string } | { kind: "outside-root" } | { kind: "not-found" };

/**
 * Resolve a path whose requested form stays inside `root`.
 *
 * Lexical `..` and absolute escapes are `outside-root`. In-tree symlink names
 * are followed to their real path even when the target is outside `root`,
 * unless `confineSymlinks` is set, which makes such a target `outside-root`
 * too. A path that does not exist is `not-found`.
 */
export async function resolveContainedPathResult(
  root: string,
  requestedPath: string,
  options: ContainedPathOptions = {},
): Promise<ContainedPathResult> {
  // Absolute paths must not be joined onto the root. Node path.join may either
  // discard the root or append the absolute segment; both break sandbox guest
  // paths mapped onto the host mount.
  const joined =
    !requestedPath || requestedPath === "."
      ? root
      : isAbsolute(requestedPath)
        ? requestedPath
        : join(root, requestedPath);

  if (requestedPath.includes("\0") || !isPathWithinRoot(resolve(joined), resolve(root))) {
    return { kind: "outside-root" };
  }

  let real: string;
  try {
    real = await realpath(joined);
  } catch {
    return { kind: "not-found" };
  }
  if (options.confineSymlinks) {
    let realRoot: string;
    try {
      realRoot = await realpath(root);
    } catch {
      return { kind: "not-found" };
    }
    if (!isPathWithinRoot(real, realRoot)) return { kind: "outside-root" };
  }
  return { kind: "ok", path: real };
}

/** `resolveContainedPathResult`'s real path, or null when there is none. */
export async function resolveContainedPath(
  root: string,
  requestedPath: string,
  options: ContainedPathOptions = {},
): Promise<string | null> {
  const result = await resolveContainedPathResult(root, requestedPath, options);
  return result.kind === "ok" ? result.path : null;
}

/** The page a listing request asks for: `?after=<name>`, or the first. */
export function listingCursor(url: URL): string | undefined {
  return url.searchParams.get("after") || undefined;
}

/** The wire shape of one listed page. */
export function directoryListingResponse(
  path: string,
  page: { entries: FileEntry[]; next: string | null },
): DirectoryListingResponse {
  return { path, entries: page.entries, truncated: page.next !== null, next: page.next };
}

export type DirectoryListingResult =
  | { kind: "ok"; entries: FileEntry[]; next: string | null }
  | { kind: "outside-root" }
  | { kind: "not-found" };

/**
 * List one page of a contained directory: `outside-root` for a path that
 * leaves `root` (`resolveContainedPathResult`), `not-found` for one that is
 * missing, unreadable, or not a directory.
 *
 * Pages follow the names in byte order (`compareDirEntryNames`, Node's
 * order on every runtime). A page holds at most `limit` entries after the
 * name `after` (exclusive), and `next` is the last name it looked at while
 * more follow, else null. Paging by name, not by position, means an entry
 * added or removed between pages never shifts another into a page twice or
 * out of every page. Clients arrange entries for display themselves.
 *
 * Known residual risk: the directory is checked by realpath and then read by
 * path. Node has no readdir-by-fd, so a guest that swaps a parent directory
 * for a symlink between the check and `readdir` can expose outside entry
 * names and metadata to the owner for that one listing. Byte reads do not
 * share this race; `sendFileBytes` verifies the opened handle.
 */
export async function listDirectoryEntries(
  root: string,
  dirRelPath: string,
  options: ContainedPathOptions & { after?: string; limit?: number } = {},
): Promise<DirectoryListingResult> {
  const limit = options.limit ?? DIRECTORY_PAGE_SIZE;
  const notFound = { kind: "not-found" } as const;
  const contained = await resolveContainedPathResult(root, dirRelPath || ".", options);
  if (contained.kind !== "ok") return contained;
  const resolvedDir = contained.path;

  let dirStat: Stats;
  try {
    dirStat = await stat(resolvedDir);
  } catch {
    return notFound;
  }
  if (!dirStat.isDirectory()) return notFound;

  let dirents: Dirent[];
  try {
    // Sorted before paging, so a page does not depend on the runtime's readdir order.
    dirents = (await readdir(resolvedDir, { withFileTypes: true })).sort((a, b) =>
      compareDirEntryNames(a.name, b.name),
    );
  } catch {
    return notFound;
  }
  const after = options.after;
  let start = 0;
  if (after !== undefined) {
    // First name past `after`.
    let high = dirents.length;
    while (start < high) {
      const mid = (start + high) >>> 1;
      if (compareDirEntryNames(dirents[mid].name, after) <= 0) start = mid + 1;
      else high = mid;
    }
  }

  let confinedRoot: string | undefined;
  if (options.confineSymlinks) {
    try {
      confinedRoot = await realpath(root);
    } catch {
      return notFound;
    }
  }

  const entryFor = async (dirent: Dirent): Promise<FileEntry | null> => {
    const entryPath = join(resolvedDir, dirent.name);
    try {
      // Sandbox listings do not report size/mtime/type of a target outside the mount.
      if (
        confinedRoot &&
        dirent.isSymbolicLink() &&
        !isPathWithinRoot(await realpath(entryPath), confinedRoot)
      ) {
        return null;
      }
      const entryStat = await stat(entryPath);
      return {
        name: dirent.name,
        type: entryStat.isDirectory() ? "directory" : "file",
        size: entryStat.size,
        modifiedAt: Math.floor(entryStat.mtimeMs),
      };
    } catch {
      // Gone since readdir, or a dangling symlink.
      return null;
    }
  };

  const entries: FileEntry[] = [];
  let index = start;
  // Skipped entries (escaping or vanished) do not count, so a page fills
  // from further on; one batch at a time keeps the page in name order.
  while (entries.length < limit && index < dirents.length) {
    const batch = dirents.slice(index, index + Math.min(STAT_BATCH, limit - entries.length));
    index += batch.length;
    for (const entry of await Promise.all(batch.map(entryFor))) {
      if (entry) entries.push(entry);
    }
  }

  const next = index < dirents.length && index > 0 ? dirents[index - 1].name : null;
  return { kind: "ok", entries, next };
}
