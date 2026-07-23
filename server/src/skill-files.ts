import { createHash, randomUUID } from "node:crypto";
import {
  closeSync,
  constants,
  existsSync,
  fsyncSync,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

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

export class SkillFileTooLargeError extends Error {
  constructor() {
    super(`Skill file content is too large (maximum ${MAX_SKILL_FILE_BYTES} bytes)`);
    this.name = "SkillFileTooLargeError";
  }
}

export class SkillFileInvalidTextError extends Error {
  constructor() {
    super("Skill file content must be valid Unicode text");
    this.name = "SkillFileInvalidTextError";
  }
}

export class SkillFileConflictError extends Error {
  constructor() {
    super("Skill file changed since it was read");
    this.name = "SkillFileConflictError";
  }
}

export interface SkillFileSnapshot {
  content: string;
  revision: string;
}

export interface SkillFileRaceHooks {
  /** Test seam for deterministic path-substitution coverage. */
  beforeOpen?: () => void;
  /** Test seam for deterministic stale-write coverage. */
  beforeRenameValidation?: () => void;
  /** Test seam for deterministic final compare-and-replace coverage. */
  beforeAtomicReplace?: () => void;
  /** Test seam for deterministic durability-failure coverage. */
  beforeDirectorySync?: () => void;
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

/** Atomically replaces one existing, regular, non-symlink file inside a Skill directory. */
export function writeSkillFile(
  baseDir: string,
  relativePath: string,
  content: string,
  expectedRevision: string,
  raceHooks: SkillFileRaceHooks = {},
): SkillFileSnapshot {
  if (Buffer.byteLength(content, "utf8") > MAX_SKILL_FILE_BYTES) {
    throw new SkillFileTooLargeError();
  }
  if (hasUnpairedSurrogate(content)) {
    throw new SkillFileInvalidTextError();
  }

  let temporaryPath: string | undefined;
  try {
    const resolved = resolveExistingSkillFile(baseDir, relativePath);
    const current = readResolvedSkillFile(resolved);
    if (current.snapshot.revision !== expectedRevision) throw new SkillFileConflictError();

    const targetDirectory = dirname(resolved.realPath);
    const directoryIdentity = resolved.parentIdentities.find(
      (entry) => entry.path === targetDirectory,
    )?.identity;
    if (!directoryIdentity) throw new SkillFileNotFoundError();
    assertParentIdentities(resolved);
    temporaryPath = join(
      targetDirectory,
      `.${basename(resolved.realPath)}.${process.pid}.${randomUUID()}.tmp`,
    );
    const descriptor = openSync(
      temporaryPath,
      constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW,
      current.mode,
    );
    try {
      writeFileSync(descriptor, content, { encoding: "utf8" });
      fsyncSync(descriptor);
    } finally {
      closeSync(descriptor);
    }

    raceHooks.beforeRenameValidation?.();

    // Re-open the target and compare descriptor identity plus content revision.
    // This detects substitutions between validation and the atomic rename.
    const latest = readResolvedSkillFileForConflict(resolved);
    if (
      !sameIdentity(latest.identity, current.identity) ||
      latest.snapshot.revision !== expectedRevision ||
      !sameIdentity(fileIdentity(statSync(targetDirectory, { bigint: true })), directoryIdentity)
    ) {
      throw new SkillFileConflictError();
    }

    raceHooks.beforeAtomicReplace?.();
    const atReplace = readResolvedSkillFileForConflict(resolved);
    if (
      !sameIdentity(atReplace.identity, current.identity) ||
      atReplace.snapshot.revision !== expectedRevision
    ) {
      throw new SkillFileConflictError();
    }
    renameSync(temporaryPath, resolved.realPath);
    temporaryPath = undefined;
    raceHooks.beforeDirectorySync?.();
    fsyncDirectory(targetDirectory);
    return { content, revision: revisionForBytes(Buffer.from(content, "utf8")) };
  } finally {
    if (temporaryPath && existsSync(temporaryPath)) {
      try {
        unlinkSync(temporaryPath);
      } catch {
        // A failed replacement remains observable through the original error.
      }
    }
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

function readResolvedSkillFileForConflict(
  resolved: ResolvedSkillFile,
): ReturnType<typeof readResolvedSkillFile> {
  try {
    return readResolvedSkillFile(resolved);
  } catch (error: unknown) {
    if (error instanceof SkillFileNotFoundError) throw new SkillFileConflictError();
    throw error;
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

function fsyncDirectory(path: string): void {
  const descriptor = openSync(path, constants.O_RDONLY);
  try {
    fsyncSync(descriptor);
  } finally {
    closeSync(descriptor);
  }
}

function hasUnpairedSurrogate(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      if (index + 1 >= value.length) return true;
      const next = value.charCodeAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) return true;
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return true;
    }
  }
  return false;
}
