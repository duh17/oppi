import type { Dirent, Stats } from "node:fs";
import { readdir, realpath, stat } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";

import { isPathWithinRoot } from "./git-utils.js";
import type { FileEntry } from "./types.js";

const MAX_DIR_ENTRIES = 1000;

function isLexicallyInsideRoot(candidate: string, root: string): boolean {
  const resolvedRoot = resolve(root);
  const resolvedCandidate = resolve(candidate);
  if (resolvedCandidate === resolvedRoot) return true;
  const normalizedRoot = resolvedRoot.endsWith("/") ? resolvedRoot : `${resolvedRoot}/`;
  return resolvedCandidate.startsWith(normalizedRoot);
}

export interface ContainedPathOptions {
  /** Sandbox mounts: the realpath must also stay inside the root's realpath. */
  confineSymlinks?: boolean;
}

/**
 * Resolve a path whose requested form stays inside `root`.
 *
 * Lexical `..` and absolute escapes are rejected. In-tree symlink names are
 * followed to their real path even when the target is outside `root`, unless
 * `confineSymlinks` is set.
 *
 * Returns the canonical absolute path if it is valid and accessible, or
 * `null` if the path does not exist or leaves `root`.
 */
export async function resolveContainedPath(
  root: string,
  requestedPath: string,
  options: ContainedPathOptions = {},
): Promise<string | null> {
  // Absolute paths must not be joined onto the root. Node path.join may either
  // discard the root or append the absolute segment; both break sandbox guest
  // paths mapped onto the host mount.
  const joined =
    !requestedPath || requestedPath === "."
      ? root
      : isAbsolute(requestedPath)
        ? requestedPath
        : join(root, requestedPath);

  if (!isLexicallyInsideRoot(joined, root)) {
    return null;
  }

  try {
    const real = await realpath(joined);
    if (options.confineSymlinks && !isPathWithinRoot(real, await realpath(root))) return null;
    return real;
  } catch {
    return null;
  }
}

/**
 * List entries in a contained directory. Returns null if path is invalid or not a directory.
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
  options: ContainedPathOptions = {},
): Promise<{ entries: FileEntry[]; truncated: boolean } | null> {
  const resolvedDir = await resolveContainedPath(root, dirRelPath || ".", options);
  if (!resolvedDir) return null;

  let dirStat: Stats;
  try {
    dirStat = await stat(resolvedDir);
  } catch {
    return null;
  }
  if (!dirStat.isDirectory()) return null;

  let dirents: Dirent[];
  try {
    dirents = await readdir(resolvedDir, { withFileTypes: true });
  } catch {
    return null;
  }

  let confinedRoot: string | undefined;
  if (options.confineSymlinks) {
    try {
      confinedRoot = await realpath(root);
    } catch {
      return null;
    }
  }

  const entries: FileEntry[] = [];
  let truncated = false;

  for (const dirent of dirents) {
    if (entries.length >= MAX_DIR_ENTRIES) {
      truncated = true;
      break;
    }

    const entryPath = join(resolvedDir, dirent.name);
    try {
      // Sandbox listings do not report size/mtime/type of a target outside the mount.
      if (
        confinedRoot &&
        dirent.isSymbolicLink() &&
        !isPathWithinRoot(await realpath(entryPath), confinedRoot)
      ) {
        continue;
      }
      const entryStat = await stat(entryPath);
      const isDir = entryStat.isDirectory();

      entries.push({
        name: dirent.name,
        type: isDir ? "directory" : "file",
        size: entryStat.size,
        modifiedAt: Math.floor(entryStat.mtimeMs),
      });
    } catch {
      continue;
    }
  }

  entries.sort((a, b) => {
    if (a.type !== b.type) return a.type === "directory" ? -1 : 1;
    return a.name.localeCompare(b.name);
  });

  return { entries, truncated };
}
