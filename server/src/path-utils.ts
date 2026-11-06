/**
 * Shared path utilities: the single home-expansion and containment rules, plus path
 * normalization for git-status, workspace-review, and session routes.
 */

import { homedir } from "node:os";
import { isAbsolute, relative, sep } from "node:path";

/**
 * Expand a leading `~` or `~/` to `home`. `~user` forms, the empty string, and
 * everything else come back unchanged: `~bob/x` is not `<home>bob/x`.
 */
export function expandHome(path: string): string {
  return path === "~" || path.startsWith("~/") ? homedir() + path.slice(1) : path;
}

/**
 * Whether `candidate` is `root` or lies under it. The one containment rule.
 *
 * Both paths must be absolute (an empty or relative path is never contained, so it can't
 * silently mean the cwd). `..` segments and trailing separators are normalized first, the
 * comparison is case-sensitive, and a sibling that shares a name prefix (`/a/bc` vs `/a/b`)
 * is outside. The check is lexical: it does not follow symlinks, so a caller guarding a
 * filesystem boundary passes realpaths.
 */
export function isPathWithinRoot(candidate: string, root: string): boolean {
  if (!isAbsolute(candidate) || !isAbsolute(root)) return false;
  const rel = relative(root, candidate);
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
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
    const root = expandHome(workspaceRoot);
    if (isPathWithinRoot(normalized, root)) normalized = relative(root, normalized) || normalized;
  }

  return normalized.replace(/\\/g, "/");
}
