import { createHash } from "node:crypto";
import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
} from "node:fs";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

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

export interface SkillFileSnapshot {
  content: string;
  revision: string;
}

export interface SkillFileRaceHooks {
  /** Test seam for deterministic path-substitution coverage. */
  beforeOpen?: () => void;
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
    relativePath.includes("\\") ||
    isAbsolute(relativePath) ||
    relativePath.split("/").some((part) => part === "." || part === ".." || part.length === 0)
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
  return readSkillFileSnapshot(baseDir, relativePath).content;
}

export function readSkillFileSnapshot(
  baseDir: string,
  relativePath: string,
  raceHooks: SkillFileRaceHooks = {},
): SkillFileSnapshot {
  try {
    const resolved = resolveExistingSkillFile(baseDir, relativePath);
    raceHooks.beforeOpen?.();
    return readResolvedSkillFile(resolved).snapshot;
  } catch (error: unknown) {
    if (error instanceof SkillFileNotFoundError) throw error;
    throw new SkillFileNotFoundError();
  }
}

interface ResolvedSkillFile {
  realBase: string;
  realPath: string;
  targetIdentity: FileIdentity;
  parentIdentities: Array<{ path: string; identity: FileIdentity }>;
}

interface FileIdentity {
  device: bigint;
  inode: bigint;
}

function resolveExistingSkillFile(baseDir: string, relativePath: string): ResolvedSkillFile {
  const safePath = safeRelativePath(relativePath);
  const realBase = realSkillBase(baseDir);
  const requested = resolve(baseDir, safePath);
  if (!isWithin(resolve(baseDir), requested) || pathHasSymlink(baseDir, safePath)) {
    throw new SkillFileNotFoundError();
  }
  const realPath = realpathSync(requested);
  if (!isWithin(realBase, realPath)) throw new SkillFileNotFoundError();
  const target = lstatSync(realPath, { bigint: true });
  if (!target.isFile() || target.isSymbolicLink()) throw new SkillFileNotFoundError();
  return {
    realBase,
    realPath,
    targetIdentity: fileIdentity(target),
    parentIdentities: collectParentIdentities(realBase, realPath),
  };
}

function readResolvedSkillFile(resolved: ResolvedSkillFile): {
  snapshot: SkillFileSnapshot;
  identity: FileIdentity;
  mode: number;
} {
  if (!isWithin(resolved.realBase, resolved.realPath)) throw new SkillFileNotFoundError();
  assertParentIdentities(resolved);

  const descriptor = openSync(resolved.realPath, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const actual = fstatSync(descriptor, { bigint: true });
    const identity = fileIdentity(actual);
    if (
      !actual.isFile() ||
      actual.size > BigInt(MAX_SKILL_FILE_BYTES) ||
      !sameIdentity(identity, resolved.targetIdentity)
    ) {
      throw new SkillFileNotFoundError();
    }
    const bytes = readFileSync(descriptor);
    const content = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return {
      snapshot: { content, revision: revisionForBytes(bytes) },
      identity,
      mode: Number(actual.mode & 0o777n),
    };
  } finally {
    closeSync(descriptor);
  }
}

function collectParentIdentities(
  realBase: string,
  realPath: string,
): Array<{ path: string; identity: FileIdentity }> {
  const identities: Array<{ path: string; identity: FileIdentity }> = [];
  let current = dirname(realPath);
  while (true) {
    if (!isWithin(realBase, current)) throw new SkillFileNotFoundError();
    const stat = lstatSync(current, { bigint: true });
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new SkillFileNotFoundError();
    identities.push({ path: current, identity: fileIdentity(stat) });
    if (current === realBase) return identities;
    const parent = dirname(current);
    if (parent === current) throw new SkillFileNotFoundError();
    current = parent;
  }
}

function assertParentIdentities(resolved: ResolvedSkillFile): void {
  for (const expected of resolved.parentIdentities) {
    const stat = lstatSync(expected.path, { bigint: true });
    if (
      !stat.isDirectory() ||
      stat.isSymbolicLink() ||
      !sameIdentity(fileIdentity(stat), expected.identity)
    ) {
      throw new SkillFileNotFoundError();
    }
  }
}

function fileIdentity(stat: { dev: bigint; ino: bigint }): FileIdentity {
  return { device: stat.dev, inode: stat.ino };
}

function sameIdentity(left: FileIdentity, right: FileIdentity): boolean {
  return left.device === right.device && left.inode === right.inode;
}

function revisionForBytes(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}
