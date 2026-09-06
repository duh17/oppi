import type { Dirent, Stats } from "node:fs";
import { readdir, realpath, stat } from "node:fs/promises";
import { isAbsolute, join } from "node:path";

import type { FileEntry } from "./types.js";

const MAX_DIR_ENTRIES = 1000;

async function resolveRootPath(root: string): Promise<string> {
  try {
    return await realpath(root);
  } catch {
    return root;
  }
}

/**
 * Resolve a path that must stay inside `root` after realpath.
 *
 * Returns the canonical absolute path if it is valid and accessible, or
 * `null` if the path does not exist or escapes the root via symlinks or
 * `..` traversal.
 */
export async function resolveContainedPath(
  root: string,
  requestedPath: string,
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

  let realFile: string;
  try {
    realFile = await realpath(joined);
  } catch {
    return null;
  }

  const realRoot = await resolveRootPath(root);
  const normalizedRoot = realRoot.endsWith("/") ? realRoot : realRoot + "/";
  if (realFile !== realRoot && !realFile.startsWith(normalizedRoot)) {
    return null;
  }

  return realFile;
}

/** List entries in a contained directory. Returns null if path is invalid or not a directory. */
export async function listDirectoryEntries(
  root: string,
  dirRelPath: string,
): Promise<{ entries: FileEntry[]; truncated: boolean } | null> {
  const resolvedDir = await resolveContainedPath(root, dirRelPath || ".");
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

  const entries: FileEntry[] = [];
  let truncated = false;

  for (const dirent of dirents) {
    if (entries.length >= MAX_DIR_ENTRIES) {
      truncated = true;
      break;
    }

    const entryPath = join(resolvedDir, dirent.name);
    try {
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
