/**
 * Shared path utilities used across git-status, workspace-review, and session routes.
 */

import { homedir } from "node:os";
import { isAbsolute, relative } from "node:path";

/** Resolve a leading `~` to the user's home directory. */
export function resolveHomePath(path: string): string {
  return path.replace(/^~/, homedir());
}

/** Check whether `candidatePath` is within `rootPath` (exact match or child). */
export function isPathWithinRoot(candidatePath: string, rootPath: string): boolean {
  return candidatePath === rootPath || candidatePath.startsWith(`${rootPath}/`);
}

/**
 * Normalize a file path for comparison.
 *
 * Trims whitespace, strips leading `./`, normalizes backslashes to forward slashes.
 * When `workspaceRoot` is provided and the path is absolute, attempts to relativize
 * it against the root.
 */
export function normalizePath(path: string, workspaceRoot?: string): string {
  let normalized = path.trim();
  if (!normalized) return "";

  while (normalized.startsWith("./")) {
    normalized = normalized.slice(2);
  }

  if (workspaceRoot && isAbsolute(normalized)) {
    const rel = relative(resolveHomePath(workspaceRoot), normalized);
    if (rel && !rel.startsWith("..") && !isAbsolute(rel)) {
      normalized = rel;
    }
  }

  return normalized.replace(/\\/g, "/");
}
