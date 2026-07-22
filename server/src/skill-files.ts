import { lstatSync, readFileSync, readdirSync, realpathSync, statSync } from "node:fs";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

export const MAX_SKILL_FILE_BYTES = 1024 * 1024;
export const MAX_SKILL_LISTED_FILES = 500;

const SKIPPED_DIRECTORIES = new Set([
  "__pycache__",
  "node_modules",
  ".git",
  ".venv",
  ".mypy_cache",
  ".pytest_cache",
  ".ruff_cache",
  "__pypackages__",
]);
const SKIPPED_EXTENSIONS = new Set([".pyc", ".pyo", ".o", ".so", ".dylib"]);

export class SkillFileNotFoundError extends Error {
  constructor() {
    super("Skill file not found");
    this.name = "SkillFileNotFoundError";
  }
}

function isWithin(base: string, candidate: string): boolean {
  const rel = relative(base, candidate);
  return rel === "" || (!rel.startsWith(`..${sep}`) && rel !== ".." && !isAbsolute(rel));
}

function realSkillBase(baseDir: string): string {
  const stat = lstatSync(baseDir);
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new SkillFileNotFoundError();
  }
  return realpathSync(baseDir);
}

function pathHasSymlink(baseDir: string, relativePath: string): boolean {
  const segments = relativePath.split(/[\\/]+/).filter(Boolean);
  let current = baseDir;
  for (const segment of segments) {
    current = join(current, segment);
    if (lstatSync(current).isSymbolicLink()) return true;
  }
  return false;
}

function safeRelativePath(relativePath: string): string {
  if (
    relativePath.length === 0 ||
    relativePath.includes("\0") ||
    isAbsolute(relativePath) ||
    relativePath.split(/[\\/]+/).some((part) => part === "..")
  ) {
    throw new SkillFileNotFoundError();
  }
  return relativePath;
}

export function listSkillFiles(baseDir: string): string[] {
  let realBase: string;
  try {
    realBase = realSkillBase(baseDir);
  } catch {
    return [];
  }

  const files: string[] = [];
  const visit = (relativeDir: string): void => {
    if (files.length >= MAX_SKILL_LISTED_FILES) return;
    const directory = relativeDir ? join(baseDir, relativeDir) : baseDir;
    let entries;
    try {
      entries = readdirSync(directory, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      if (files.length >= MAX_SKILL_LISTED_FILES) return;
      const relativePath = relativeDir ? `${relativeDir}/${entry.name}` : entry.name;
      const fullPath = join(directory, entry.name);
      try {
        const stat = lstatSync(fullPath);
        if (stat.isSymbolicLink()) continue;
        const realPath = realpathSync(fullPath);
        if (!isWithin(realBase, realPath)) continue;
        if (stat.isDirectory()) {
          if (!SKIPPED_DIRECTORIES.has(entry.name)) visit(relativePath);
          continue;
        }
        if (!stat.isFile()) continue;
        const dot = entry.name.lastIndexOf(".");
        const extension = dot >= 0 ? entry.name.slice(dot) : "";
        if (!SKIPPED_EXTENSIONS.has(extension)) files.push(relativePath);
      } catch {
        // Unreadable or concurrently removed entries are omitted.
      }
    }
  };

  visit("");
  return files;
}

export function readSkillFile(baseDir: string, relativePath: string): string {
  try {
    const safePath = safeRelativePath(relativePath);
    const realBase = realSkillBase(baseDir);
    const requested = resolve(baseDir, safePath);
    if (!isWithin(resolve(baseDir), requested) || pathHasSymlink(baseDir, safePath)) {
      throw new SkillFileNotFoundError();
    }
    const realPath = realpathSync(requested);
    if (!isWithin(realBase, realPath)) throw new SkillFileNotFoundError();
    const stat = statSync(realPath);
    if (!stat.isFile() || stat.size > MAX_SKILL_FILE_BYTES) {
      throw new SkillFileNotFoundError();
    }
    const bytes = readFileSync(realPath);
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch (error: unknown) {
    if (error instanceof SkillFileNotFoundError) throw error;
    throw new SkillFileNotFoundError();
  }
}
