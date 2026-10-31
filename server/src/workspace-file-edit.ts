/**
 * File editor write contract (I0): workspace files, editable Skill files, and
 * Pi's own allowlisted agent files.
 *
 * Reads and writes share one eligibility predicate that is stricter than
 * host-workspace current-file fallbacks (`~`, host-absolute, `..`).
 *
 * Atomic rename is not compare-and-swap against agent, git, or shell writers.
 * An in-process mutex serializes editor PUTs for the same canonical file.
 * Rename and temp cleanup are path operations, not inode-safe. A same-host
 * writer that swaps the temp name after the last inode and byte check, or
 * between cleanup's lstat and unlink, is an accepted residual race.
 *
 * Only a target that names where a *missing* file may appear creates one
 * (`createsIn`), and only on `If-None-Match: *`: the bytes are written and
 * fsynced to a temp beside the target and then `link`ed into place, so the
 * final name never holds a partial document and a file another writer created
 * first is a 412. A workspace file and a Skill file never create.
 *
 * Residual race, same-user only: `O_NOFOLLOW` and the containment checks cover
 * the path this request resolves, not a parent directory swapped for a link
 * after that. A writer with the owner's own rights who swaps `prompts/` between
 * the check and the link can make this request's temp file land in the swap
 * target (a transient empty file there) or leave an orphaned temp in the real
 * `prompts/`; the bytes never go anywhere the target did not name at check time,
 * and the same user could write both places directly. This is the same class as
 * the rename race above, and it is accepted for the same reason.
 */

import { createHash, randomBytes } from "node:crypto";
import { constants } from "node:fs";
import * as fs from "node:fs/promises";
import type { FileHandle } from "node:fs/promises";
import type { IncomingMessage } from "node:http";
import { dirname, isAbsolute, join, resolve, basename } from "node:path";

import { isWorkspaceEditorTextPath, MAX_WORKSPACE_FILE_EDIT_BYTES } from "./file-serving-policy.js";
import { isPathWithinRoot } from "./git-utils.js";
import type { Workspace, WorkspaceFileEditWriteResponse } from "./types.js";
import { resolveWorkspaceUserPath } from "./workspace-user-path.js";

export const WORKSPACE_FILE_EDIT_MAX_BYTES = MAX_WORKSPACE_FILE_EDIT_BYTES;

/**
 * Response header on the editor's read of a file that does not exist yet: the
 * body is empty, there is no ETag, and a `PUT` with `If-None-Match: *` creates
 * it. Only Pi's own allowlisted files answer it.
 */
export const FILE_EDIT_CREATABLE_HEADER = "X-Oppi-Creatable";

const IF_MATCH_RE = /^"sha256-[0-9a-f]{64}"$/;
const TEMP_PREFIX = ".oppi-edit-";
const TEMP_SUFFIX = ".tmp";
const TEMP_OPEN_FLAGS =
  constants.O_RDWR | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW;
/** A file the editor creates: the mode a plain `writeFile` would leave. */
const NEW_FILE_MODE = 0o644;
const NEW_DIRECTORY_MODE = 0o755;

type CapturedTemp = {
  path: string;
  dev: number;
  ino: number;
};

export type FileEditInspection =
  | {
      kind: "eligible";
      bytes: Buffer;
      etag: string;
      lexicalPath: string;
      realPath: string;
      realRoot: string;
      mode: number;
      size: number;
    }
  /**
   * The file does not exist, and this target may create it: the parent is the
   * real directory the target names, so a first save can put the file there.
   * `createDirectory` means that directory is `prompts/` itself, absent today.
   */
  | {
      kind: "creatable";
      createPath: string;
      parentReal: string;
      createDirectory: boolean;
      realRoot: string;
    }
  | { kind: "not-found" }
  | { kind: "forbidden" }
  | { kind: "ineligible" };

/** One file the editor may read and write: a path that must stay under `root`. */
export interface FileEditTarget {
  /** Host directory: a workspace checkout or mount, an editable Skill's directory, or Pi's agent directory. */
  root: string;
  requestedPath: string;
  /**
   * Workspace edits accept sandbox guest paths and report escapes as 403.
   * Absent for a Skill directory, where only root-relative paths resolve.
   */
  workspace?: Workspace;
  /**
   * A narrower rule than root containment, asked about the path after symlinks
   * are resolved (root-relative, `/`-separated). Pi's agent directory uses it so
   * its allowlist names files, not a root: a symlink inside the directory cannot
   * widen what may be written.
   */
  allowsCanonical?: (relativeToRealRoot: string) => boolean;
  /**
   * Whether a *missing* file may be created, asked about the parent directory
   * (root-relative, `""` for the root itself). Absent means this target never
   * creates: a workspace file and a Skill file only ever overwrite.
   */
  createsIn?: (parentRelativeToRealRoot: string) => boolean;
}

function isSandboxed(target: { workspace?: Workspace }): boolean {
  return target.workspace?.runtime === "sandbox";
}

/** A root-relative path under `root`; `editorPathForm` already refused absolute and `..`. */
function containedRelativePath(root: string, requestedPath: string): string | null {
  const hostRoot = resolve(root);
  const candidate = resolve(hostRoot, requestedPath);
  return candidate !== hostRoot && isPathWithinRoot(candidate, hostRoot) ? candidate : null;
}

export type PutEditedFileResult =
  | { kind: "ok"; response: WorkspaceFileEditWriteResponse }
  | { kind: "error"; status: number; message: string };

/** What a write is conditioned on. One of the two headers, never both. */
export type FileEditPrecondition =
  /** `If-Match: "<sha256>"`: overwrite exactly this version. */
  | { kind: "match"; etag: string }
  /** `If-None-Match: *`: the file must not exist; this write creates it. */
  | { kind: "create" };

class Mutex {
  private queue: Array<() => void> = [];
  private locked = false;

  async acquire(): Promise<() => void> {
    if (!this.locked) {
      this.locked = true;
      return () => this.release();
    }
    return new Promise((resolve) => {
      this.queue.push(() => {
        resolve(() => this.release());
      });
    });
  }

  async withLock<T>(fn: () => Promise<T>): Promise<T> {
    const release = await this.acquire();
    try {
      return await fn();
    } finally {
      release();
    }
  }

  private release(): void {
    const next = this.queue.shift();
    if (next) {
      next();
      return;
    }
    this.locked = false;
  }
}

const editorWriteLocks = new Map<string, { mutex: Mutex; refs: number }>();

async function withEditorWriteLock<T>(key: string, fn: () => Promise<T>): Promise<T> {
  let entry = editorWriteLocks.get(key);
  if (!entry) {
    entry = { mutex: new Mutex(), refs: 0 };
    editorWriteLocks.set(key, entry);
  }
  entry.refs += 1;
  try {
    return await entry.mutex.withLock(fn);
  } finally {
    entry.refs -= 1;
    if (entry.refs === 0) editorWriteLocks.delete(key);
  }
}

function workspaceFileEtag(bytes: Buffer): string {
  return `"sha256-${createHash("sha256").update(bytes).digest("hex")}"`;
}

function isValidUtf8(bytes: Buffer): boolean {
  try {
    new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return true;
  } catch {
    return false;
  }
}

function containsNul(bytes: Buffer): boolean {
  return bytes.includes(0);
}

export function evaluateIfMatch(
  header: string | string[] | undefined,
):
  | { kind: "missing" }
  | { kind: "wildcard" }
  | { kind: "invalid" }
  | { kind: "etag"; etag: string } {
  if (header === undefined) return { kind: "missing" };
  const raw = Array.isArray(header) ? header.join(",") : header;
  const trimmed = raw.trim();
  if (!trimmed) return { kind: "missing" };
  if (trimmed === "*") return { kind: "wildcard" };
  if (IF_MATCH_RE.test(trimmed)) return { kind: "etag", etag: trimmed };
  return { kind: "invalid" };
}

/**
 * `If-None-Match` is only ever `*` here: "create this file, if it is still
 * absent". A tag or a list of them is refused rather than approximated.
 */
export function evaluateIfNoneMatch(
  header: string | string[] | undefined,
): { kind: "absent" } | { kind: "create" } | { kind: "invalid" } {
  if (header === undefined) return { kind: "absent" };
  const raw = Array.isArray(header) ? header.join(",") : header;
  const trimmed = raw.trim();
  if (!trimmed) return { kind: "absent" };
  return trimmed === "*" ? { kind: "create" } : { kind: "invalid" };
}

function editorPathForm(
  workspace: Workspace | undefined,
  requestedPath: string,
): "ok" | "ineligible" {
  if (!requestedPath || requestedPath.includes("\0")) return "ineligible";
  if (requestedPath.toLowerCase().startsWith("file:")) return "ineligible";
  if (requestedPath.startsWith("~")) return "ineligible";
  if (!isWorkspaceEditorTextPath(requestedPath)) return "ineligible";

  const normalized = requestedPath.replaceAll("\\", "/");
  if (normalized.split("/").includes("..")) return "ineligible";

  const absolute = normalized.startsWith("/") || isAbsolute(requestedPath);
  if (!absolute) return "ok";
  // Sandbox clients read guest paths (`/workspace/<slug>/...`). Host-absolute
  // paths stay ineligible even when they happen to sit on the mount.
  if (workspace?.runtime === "sandbox" && normalized.startsWith("/workspace/")) {
    return "ok";
  }
  return "ineligible";
}

/**
 * After open, prove the handle is still the path's inode and that realpath
 * stays inside the selected root. O_NOFOLLOW on the final component does not
 * stop a parent-directory symlink swap.
 */
async function proveHandleInRoot(
  handle: FileHandle,
  path: string,
  realRoot: string,
): Promise<{ realPath: string } | null> {
  let opened: Awaited<ReturnType<FileHandle["stat"]>>;
  let realPath: string;
  try {
    opened = await handle.stat();
    realPath = await fs.realpath(path);
  } catch {
    return null;
  }
  if (!isPathWithinRoot(realPath, realRoot)) return null;
  try {
    const current = await fs.stat(realPath);
    if (current.dev !== opened.dev || current.ino !== opened.ino) return null;
  } catch {
    return null;
  }
  return { realPath };
}

function inspectionError(inspection: FileEditInspection): PutEditedFileResult | null {
  if (inspection.kind === "eligible" || inspection.kind === "creatable") return null;
  if (inspection.kind === "forbidden") {
    return { kind: "error", status: 403, message: "Path outside sandbox workspace" };
  }
  return { kind: "error", status: 404, message: "File not found" };
}

/**
 * A missing file. Only a target that names where its files may appear creates
 * one, and only inside the real directory that would hold it: the parent is
 * built from the real root, so a link anywhere is refused before anything is
 * created. A missing `prompts/` is created with the first template; a deeper
 * missing directory is not.
 */
async function inspectCreatable(
  input: FileEditTarget,
  requestedPath: string,
  realRoot: string,
): Promise<FileEditInspection> {
  if (!input.createsIn) return { kind: "not-found" };
  const requested = requestedPath.replaceAll("\\", "/");
  const parent = dirname(requested);
  const parentRelative = parent === "." || parent === "" ? "" : parent;
  if (!input.createsIn(parentRelative)) return { kind: "not-found" };

  const parentPath = parentRelative ? join(realRoot, parentRelative) : realRoot;
  const createPath = join(parentPath, basename(requested));
  let parentLst: Awaited<ReturnType<typeof fs.lstat>>;
  try {
    parentLst = await fs.lstat(parentPath);
  } catch (error: unknown) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code !== "ENOENT" || parentRelative === "") return { kind: "not-found" };
    return {
      kind: "creatable",
      createPath,
      parentReal: parentPath,
      createDirectory: true,
      realRoot,
    };
  }
  if (parentLst.isSymbolicLink() || !parentLst.isDirectory()) return { kind: "not-found" };
  let parentReal: string;
  try {
    parentReal = await fs.realpath(parentPath);
  } catch {
    return { kind: "not-found" };
  }
  if (parentReal !== parentPath || !isPathWithinRoot(parentReal, realRoot)) {
    return { kind: "not-found" };
  }
  return { kind: "creatable", createPath, parentReal, createDirectory: false, realRoot };
}

/**
 * Shared editor eligibility. Stricter than host-workspace current-file reads:
 * no `~`, host-absolute, or `..` fallback, no final-component symlink, at most
 * 1 MiB, editor text types only, valid UTF-8, no NUL. Callers map `ineligible`
 * to "no ETag" on GET and existing 404 on PUT. Sandbox escape stays 403.
 * `creatable` is the one answer about a file that is not there: the target named
 * a parent it may create files in, and that parent is real.
 */
export async function inspectFileForEdit(input: FileEditTarget): Promise<FileEditInspection> {
  if (editorPathForm(input.workspace, input.requestedPath) !== "ok") {
    return { kind: "ineligible" };
  }

  const lexicalPath = input.workspace
    ? resolveWorkspaceUserPath({
        workspace: input.workspace,
        requestedPath: input.requestedPath,
        root: input.root,
      })
    : containedRelativePath(input.root, input.requestedPath);
  if (!lexicalPath) {
    return isSandboxed(input) ? { kind: "forbidden" } : { kind: "not-found" };
  }

  let realRoot: string;
  try {
    realRoot = await fs.realpath(input.root);
  } catch {
    return { kind: "not-found" };
  }

  let lst: Awaited<ReturnType<typeof fs.lstat>>;
  try {
    lst = await fs.lstat(lexicalPath);
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      return inspectCreatable(input, input.requestedPath, realRoot);
    }
    return { kind: "not-found" };
  }

  let canonical: string;
  try {
    canonical = await fs.realpath(lexicalPath);
  } catch {
    return { kind: "not-found" };
  }
  if (!isPathWithinRoot(canonical, realRoot)) {
    return isSandboxed(input) ? { kind: "forbidden" } : { kind: "ineligible" };
  }
  if (input.allowsCanonical) {
    const relativeCanonical = canonical.slice(realRoot.length + 1).replaceAll("\\", "/");
    if (!input.allowsCanonical(relativeCanonical)) {
      return isSandboxed(input) ? { kind: "forbidden" } : { kind: "ineligible" };
    }
  }
  if (lst.isSymbolicLink()) return { kind: "ineligible" };
  if (!lst.isFile()) return { kind: "not-found" };
  if (lst.size > WORKSPACE_FILE_EDIT_MAX_BYTES) return { kind: "ineligible" };

  let handle: FileHandle;
  try {
    handle = await fs.open(
      canonical,
      constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
    );
  } catch (error: unknown) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ELOOP") return { kind: "ineligible" };
    return { kind: "not-found" };
  }

  try {
    const proven = await proveHandleInRoot(handle, canonical, realRoot);
    if (!proven) {
      return isSandboxed(input) ? { kind: "forbidden" } : { kind: "ineligible" };
    }
    const opened = await handle.stat();
    if (!opened.isFile()) return { kind: "not-found" };
    if (opened.size > WORKSPACE_FILE_EDIT_MAX_BYTES) return { kind: "ineligible" };
    const bytes = await handle.readFile();
    if (bytes.length > WORKSPACE_FILE_EDIT_MAX_BYTES) return { kind: "ineligible" };
    if (containsNul(bytes) || !isValidUtf8(bytes)) return { kind: "ineligible" };
    return {
      kind: "eligible",
      bytes,
      etag: workspaceFileEtag(bytes),
      lexicalPath,
      realPath: proven.realPath,
      realRoot,
      mode: opened.mode,
      size: bytes.length,
    };
  } catch {
    return { kind: "not-found" };
  } finally {
    await handle.close().catch(() => {});
  }
}

export async function readBoundedRequestBody(
  req: IncomingMessage,
  maxBytes: number,
): Promise<{ kind: "ok"; bytes: Buffer } | { kind: "too-large" } | { kind: "error" }> {
  const declaredLength = Number(req.headers["content-length"]);
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
    return { kind: "too-large" };
  }

  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    let size = 0;
    let settled = false;
    const finish = (
      result: { kind: "ok"; bytes: Buffer } | { kind: "too-large" } | { kind: "error" },
    ): void => {
      if (settled) return;
      settled = true;
      resolve(result);
    };

    req.on("data", (chunk: Buffer | string) => {
      if (settled) return;
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += buffer.length;
      if (size > maxBytes) {
        chunks.length = 0;
        finish({ kind: "too-large" });
        return;
      }
      chunks.push(buffer);
    });
    req.on("end", () => {
      if (settled) return;
      finish({ kind: "ok", bytes: Buffer.concat(chunks) });
    });
    req.on("error", () => {
      finish({ kind: "error" });
    });
  });
}

async function unlinkCapturedTemp(temp: CapturedTemp): Promise<void> {
  try {
    const lst = await fs.lstat(temp.path);
    if (lst.dev !== temp.dev || lst.ino !== temp.ino) return;
    if (lst.isSymbolicLink()) return;
    await fs.unlink(temp.path);
  } catch {
    // Replaced or already gone. Never follow a substituted entry.
  }
}

/**
 * Last temp recheck before rename: the directory entry must still be the
 * inode we wrote and the bytes we submitted. Path containment is not enough.
 */
async function proveTempInodeAndBytes(
  temp: CapturedTemp,
  expectedBytes: Buffer,
  expectedParent: string,
  realRoot: string,
): Promise<boolean> {
  let lst: Awaited<ReturnType<typeof fs.lstat>>;
  try {
    lst = await fs.lstat(temp.path);
  } catch {
    return false;
  }
  if (lst.isSymbolicLink() || !lst.isFile()) return false;
  if (lst.dev !== temp.dev || lst.ino !== temp.ino) return false;

  let handle: FileHandle;
  try {
    handle = await fs.open(temp.path, constants.O_RDONLY | constants.O_NOFOLLOW);
  } catch {
    return false;
  }
  try {
    const opened = await handle.stat();
    if (opened.dev !== temp.dev || opened.ino !== temp.ino) return false;
    if (!opened.isFile() || opened.size !== expectedBytes.length) return false;
    const parent = await fs.realpath(dirname(temp.path));
    if (parent !== expectedParent || !isPathWithinRoot(parent, realRoot)) return false;
    const bytes = await handle.readFile();
    return bytes.equals(expectedBytes);
  } catch {
    return false;
  } finally {
    await handle.close().catch(() => {});
  }
}

async function writeEditedFileAtomic(
  input: FileEditTarget & {
    realPath: string;
    realRoot: string;
    expectedEtag: string;
    bytes: Buffer;
    mode: number;
  },
): Promise<PutEditedFileResult> {
  const permission = input.mode & 0o777;
  let captured: CapturedTemp | undefined;

  try {
    let parentReal: string;
    try {
      parentReal = await fs.realpath(dirname(input.realPath));
    } catch {
      return { kind: "error", status: 404, message: "File not found" };
    }
    if (!isPathWithinRoot(parentReal, input.realRoot)) {
      return isSandboxed(input)
        ? { kind: "error", status: 403, message: "Path outside sandbox workspace" }
        : { kind: "error", status: 404, message: "File not found" };
    }

    for (let attempt = 0; attempt < 3; attempt += 1) {
      const candidate = join(
        parentReal,
        `${TEMP_PREFIX}${randomBytes(16).toString("hex")}${TEMP_SUFFIX}`,
      );
      let handle: FileHandle;
      try {
        handle = await fs.open(candidate, TEMP_OPEN_FLAGS, permission);
      } catch (error: unknown) {
        const code = (error as NodeJS.ErrnoException).code;
        if (code === "EEXIST") continue;
        if (code === "ENOENT" || code === "ELOOP") {
          return { kind: "error", status: 404, message: "File not found" };
        }
        throw error;
      }
      try {
        const created = await handle.stat();
        captured = { path: candidate, dev: created.dev, ino: created.ino };
        const proven = await proveHandleInRoot(handle, candidate, input.realRoot);
        if (!proven) {
          return isSandboxed(input)
            ? { kind: "error", status: 403, message: "Path outside sandbox workspace" }
            : { kind: "error", status: 404, message: "File not found" };
        }
        await handle.writeFile(input.bytes);
        await handle.sync();
        await handle.chmod(permission);
        const written = await handle.stat();
        if (
          written.dev !== captured.dev ||
          written.ino !== captured.ino ||
          !written.isFile() ||
          written.size !== input.bytes.length
        ) {
          return { kind: "error", status: 500, message: "Failed to write file" };
        }
        if (input.bytes.length > 0) {
          const readback = Buffer.alloc(written.size);
          const { bytesRead } = await handle.read(readback, 0, written.size, 0);
          if (bytesRead !== written.size || !readback.equals(input.bytes)) {
            return { kind: "error", status: 500, message: "Failed to write file" };
          }
        }
        break;
      } finally {
        await handle.close().catch(() => {});
      }
    }
    if (!captured) {
      return { kind: "error", status: 500, message: "Failed to write file" };
    }

    const recheck = await inspectFileForEdit({
      workspace: input.workspace,
      root: input.root,
      requestedPath: input.requestedPath,
      ...(input.allowsCanonical ? { allowsCanonical: input.allowsCanonical } : {}),
    });
    const recheckError = inspectionError(recheck);
    if (recheckError) return recheckError;
    if (recheck.kind !== "eligible") {
      return { kind: "error", status: 404, message: "File not found" };
    }
    if (recheck.etag !== input.expectedEtag || recheck.realPath !== input.realPath) {
      return { kind: "error", status: 412, message: "Precondition failed" };
    }

    const tempStill = await proveTempInodeAndBytes(
      captured,
      input.bytes,
      parentReal,
      input.realRoot,
    );
    if (!tempStill) {
      return { kind: "error", status: 500, message: "Failed to write file" };
    }

    await fs.rename(captured.path, recheck.realPath);
    captured = undefined;

    let mtimeMs = Date.now();
    try {
      mtimeMs = (await fs.stat(recheck.realPath)).mtimeMs;
    } catch {
      // The rename landed; mtime is best-effort for the JSON body.
    }

    return {
      kind: "ok",
      response: {
        etag: workspaceFileEtag(input.bytes),
        size: input.bytes.length,
        mtimeMs,
      },
    };
  } catch {
    return { kind: "error", status: 500, message: "Failed to write file" };
  } finally {
    if (captured) await unlinkCapturedTemp(captured);
  }
}

/**
 * The file the editor creates: `O_CREAT|O_EXCL` in a parent that was proven
 * real, so a file another writer put there first is a 412 and never an
 * overwrite. The created file then has to pass the same eligibility an
 * existing one does (the target's own allowlist again, on the canonical path);
 * a file that fails it is removed again, because this request made it.
 */
async function createEditedFile(
  input: FileEditTarget & {
    creatable: Extract<FileEditInspection, { kind: "creatable" }>;
    bytes: Buffer;
  },
): Promise<PutEditedFileResult> {
  const { creatable, bytes } = input;
  const parentReal = creatable.parentReal;
  if (creatable.createDirectory) {
    try {
      await fs.mkdir(parentReal, { mode: NEW_DIRECTORY_MODE });
    } catch (error: unknown) {
      // Someone else made it meanwhile: it still has to be the real directory.
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") {
        return { kind: "error", status: 404, message: "File not found" };
      }
    }
    try {
      const lst = await fs.lstat(parentReal);
      if (lst.isSymbolicLink() || !lst.isDirectory()) {
        return { kind: "error", status: 404, message: "File not found" };
      }
      if ((await fs.realpath(parentReal)) !== parentReal) {
        return { kind: "error", status: 404, message: "File not found" };
      }
    } catch {
      return { kind: "error", status: 404, message: "File not found" };
    }
  }

  // The temp is written and fsynced beside the target, then linked into place:
  // `link` is the exclusive create (EEXIST when the name is taken), and the
  // final name never exists holding a partial document — a Pi session reading
  // SYSTEM.md mid-write would otherwise see an empty or truncated prompt.
  const createPath = creatable.createPath;
  let temp: CapturedTemp | undefined;
  let created: { dev: number; ino: number } | undefined;
  try {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const candidate = join(
        parentReal,
        `${TEMP_PREFIX}${randomBytes(16).toString("hex")}${TEMP_SUFFIX}`,
      );
      let handle: FileHandle;
      try {
        handle = await fs.open(candidate, TEMP_OPEN_FLAGS, NEW_FILE_MODE);
      } catch (error: unknown) {
        const code = (error as NodeJS.ErrnoException).code;
        if (code === "EEXIST") continue;
        if (code === "ENOENT" || code === "ELOOP") {
          return { kind: "error", status: 404, message: "File not found" };
        }
        return { kind: "error", status: 500, message: "Failed to write file" };
      }
      try {
        const opened = await handle.stat();
        temp = { path: candidate, dev: opened.dev, ino: opened.ino };
        const proven = await proveHandleInRoot(handle, candidate, creatable.realRoot);
        if (!proven) return { kind: "error", status: 404, message: "File not found" };
        await handle.writeFile(bytes);
        await handle.sync();
        const written = await handle.stat();
        if (
          written.dev !== temp.dev ||
          written.ino !== temp.ino ||
          !written.isFile() ||
          written.size !== bytes.length
        ) {
          return { kind: "error", status: 500, message: "Failed to write file" };
        }
      } finally {
        await handle.close().catch(() => {});
      }
      break;
    }
    if (!temp) return { kind: "error", status: 500, message: "Failed to write file" };
    created = { dev: temp.dev, ino: temp.ino };
    try {
      await fs.link(temp.path, createPath);
    } catch (error: unknown) {
      const code = (error as NodeJS.ErrnoException).code;
      // EEXIST: the file appeared between the read and this write. A link
      // cannot replace it, so the editor's first save is a stale conflict.
      if (code === "EEXIST" || code === "ELOOP") {
        return { kind: "error", status: 412, message: "Precondition failed" };
      }
      if (code === "ENOENT") return { kind: "error", status: 404, message: "File not found" };
      return { kind: "error", status: 500, message: "Failed to write file" };
    }
  } catch {
    if (created) await unlinkCreatedFile(createPath, created);
    return { kind: "error", status: 500, message: "Failed to write file" };
  } finally {
    if (temp) await unlinkCapturedTemp(temp);
  }

  // The file that is now there has to be one this target may write: the same
  // inspection an existing file gets, allowlist and all, on the created path.
  const check = await inspectFileForEdit(input);
  if (check.kind !== "eligible" || check.realPath !== createPath) {
    await unlinkCreatedFile(createPath, created);
    return check.kind === "forbidden"
      ? { kind: "error", status: 403, message: "Path outside sandbox workspace" }
      : { kind: "error", status: 404, message: "File not found" };
  }

  let mtimeMs = Date.now();
  try {
    mtimeMs = (await fs.stat(createPath)).mtimeMs;
  } catch {
    // The create landed; mtime is best-effort for the JSON body.
  }
  return {
    kind: "ok",
    response: { etag: workspaceFileEtag(bytes), size: bytes.length, mtimeMs },
  };
}

/**
 * Remove a file this request created, and only while it is still that inode:
 * without the handle's dev/inode there is nothing to prove the path is ours, so
 * nothing is removed.
 */
async function unlinkCreatedFile(
  path: string,
  created: { dev: number; ino: number } | undefined,
): Promise<void> {
  if (!created) return;
  try {
    const lst = await fs.lstat(path);
    if (lst.isSymbolicLink() || lst.dev !== created.dev || lst.ino !== created.ino) return;
    await fs.unlink(path);
  } catch {
    // Already gone or replaced. Never remove an entry this request did not make.
  }
}

/**
 * One editor PUT from an HTTP request: one precondition (`If-Match` for an
 * existing file, `If-None-Match: *` for one the target may create) is checked
 * before the body is read, the body is bounded, then `putEditedFile` writes.
 * `size` is the body length once read, for the route's log.
 */
export async function putEditedFileFromRequest(
  req: IncomingMessage,
  target: FileEditTarget,
): Promise<PutEditedFileResult & { size?: number }> {
  const ifMatch = evaluateIfMatch(req.headers["if-match"]);
  const ifNoneMatch = evaluateIfNoneMatch(req.headers["if-none-match"]);
  // One write, one condition: `If-Match` overwrites a version, `If-None-Match: *`
  // creates a file that must still be absent. Both at once, or a form this
  // server does not act on, is refused before the body is read.
  let precondition: FileEditPrecondition;
  if (ifNoneMatch.kind === "create") {
    if (ifMatch.kind !== "missing") {
      return { kind: "error", status: 412, message: "Precondition failed" };
    }
    precondition = { kind: "create" };
  } else if (ifMatch.kind === "etag" && ifNoneMatch.kind === "absent") {
    precondition = { kind: "match", etag: ifMatch.etag };
  } else if (ifMatch.kind === "missing" && ifNoneMatch.kind === "absent") {
    return { kind: "error", status: 428, message: "If-Match precondition required" };
  } else {
    return { kind: "error", status: 412, message: "Precondition failed" };
  }

  const body = await readBoundedRequestBody(req, WORKSPACE_FILE_EDIT_MAX_BYTES);
  if (body.kind === "too-large") {
    req.resume();
    return {
      kind: "error",
      status: 413,
      message: `File too large (max ${Math.round(WORKSPACE_FILE_EDIT_MAX_BYTES / (1024 * 1024))}MB)`,
    };
  }
  if (body.kind === "error") {
    return { kind: "error", status: 400, message: "Failed to read body" };
  }
  const result = await putEditedFile({
    ...target,
    precondition,
    body: body.bytes,
  });
  return { ...result, size: body.bytes.length };
}

export async function putEditedFile(
  input: FileEditTarget & {
    precondition: FileEditPrecondition;
    body: Buffer;
  },
): Promise<PutEditedFileResult> {
  const { precondition } = input;
  if (input.body.length > WORKSPACE_FILE_EDIT_MAX_BYTES) {
    return {
      kind: "error",
      status: 413,
      message: `File too large (max ${Math.round(WORKSPACE_FILE_EDIT_MAX_BYTES / (1024 * 1024))}MB)`,
    };
  }
  if (containsNul(input.body) || !isValidUtf8(input.body)) {
    return { kind: "error", status: 415, message: "Invalid UTF-8" };
  }

  const first = await inspectFileForEdit(input);
  if (first.kind === "creatable") {
    // Only `If-None-Match: *` creates. An `If-Match` write to a file that is
    // not there is the 404 it always was.
    if (precondition.kind !== "create") {
      return { kind: "error", status: 404, message: "File not found" };
    }
    const creatable = first;
    return withEditorWriteLock(creatable.createPath, async () => {
      const recheck = await inspectFileForEdit(input);
      if (recheck.kind !== "creatable" || recheck.createPath !== creatable.createPath) {
        // The file appeared (412: this create can no longer apply) or its
        // parent stopped being creatable (404: there is nowhere to put it).
        return recheck.kind === "eligible"
          ? { kind: "error", status: 412, message: "Precondition failed" }
          : { kind: "error", status: 404, message: "File not found" };
      }
      return createEditedFile({ ...input, creatable: recheck, bytes: input.body });
    });
  }
  const firstError = inspectionError(first);
  if (firstError) return firstError;
  if (first.kind !== "eligible") {
    return { kind: "error", status: 404, message: "File not found" };
  }
  if (precondition.kind === "create") {
    // "Must not exist" and it does: nothing was written, and a create never
    // overwrites what it did not make.
    return { kind: "error", status: 412, message: "Precondition failed" };
  }

  // The canonical file is the lock: a Skill inside a workspace checkout is
  // one file whichever route edits it.
  return withEditorWriteLock(first.realPath, async () => {
    const inspection = await inspectFileForEdit(input);
    const error = inspectionError(inspection);
    if (error) return error;
    if (inspection.kind !== "eligible") {
      return { kind: "error", status: 404, message: "File not found" };
    }
    if (inspection.etag !== precondition.etag || inspection.realPath !== first.realPath) {
      return { kind: "error", status: 412, message: "Precondition failed" };
    }
    return writeEditedFileAtomic({
      workspace: input.workspace,
      root: input.root,
      requestedPath: input.requestedPath,
      realPath: inspection.realPath,
      realRoot: inspection.realRoot,
      expectedEtag: precondition.etag,
      bytes: input.body,
      mode: inspection.mode,
      ...(input.allowsCanonical ? { allowsCanonical: input.allowsCanonical } : {}),
    });
  });
}
