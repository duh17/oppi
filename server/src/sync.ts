/**
 * File sync utilities for sandbox session setup.
 *
 * Extracted from SandboxManager for testability.
 * All functions resolve symlinks before copying so container
 * sessions receive real files, not host-absolute symlinks.
 */

import {
  existsSync,
  readFileSync,
  writeFileSync,
  rmSync,
  chmodSync,
  statSync,
  realpathSync,
} from "node:fs";

/**
 * Copy file content while resolving source symlinks.
 * The destination is always a regular file with the source's content.
 * Avoids absolute host symlinks that containers cannot follow.
 */
export function copyFileDereferenced(src: string, dest: string, opts?: { mode?: number }): void {
  const content = readFileSync(resolvePath(src));
  writeFileSync(dest, content);
  if (opts?.mode) chmodSync(dest, opts.mode);
}

/**
 * Sync a file from src to dest, dereferencing symlinks.
 * Skips if source doesn't exist. Only copies if dest is missing or older.
 */
export function syncFile(src: string, dest: string, opts?: { mode?: number }): void {
  if (!existsSync(src)) return;
  if (!existsSync(dest) || isNewer(src, dest)) {
    copyFileDereferenced(src, dest, opts);
  }
}

/**
 * Conditionally sync an optional file.
 * If disabled, removes the destination. If enabled, copies with dereference.
 */
export function syncOptionalFile(src: string, dest: string, enabled: boolean): void {
  if (!enabled) {
    if (existsSync(dest)) rmSync(dest);
    return;
  }

  if (!existsSync(src)) {
    console.log(`[sandbox] ⚠ Optional file not found, skipping: ${src}`);
    return;
  }

  if (!existsSync(dest) || isNewer(src, dest)) {
    copyFileDereferenced(src, dest);
  }
}

/** Check if file `a` has a more recent mtime than file `b`. */
export function isNewer(a: string, b: string): boolean {
  try {
    return statSync(a).mtimeMs > statSync(b).mtimeMs;
  } catch {
    return false;
  }
}

/** Resolve symlinks, falling back to original path on error. */
export function resolvePath(p: string): string {
  try {
    return realpathSync(p);
  } catch {
    return p;
  }
}
