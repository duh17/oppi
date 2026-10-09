import { chmodSync, lstatSync, mkdirSync } from "node:fs";

/**
 * Make `path` a real owner-only directory, or throw `errorMessage`. Only the leaf is created
 * (the parent must exist) and the result is checked with `lstat`, so a symlink planted at the
 * path is refused rather than followed or adopted. An existing real directory is reused.
 */
export function ensureOwnerOnlyRealDirectory(path: string, errorMessage: string): void {
  try {
    mkdirSync(path, { mode: 0o700 });
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException | undefined)?.code !== "EEXIST") {
      throw error;
    }
  }
  const stat = lstatSync(path);
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    throw new Error(errorMessage);
  }
  chmodSync(path, 0o700);
}
