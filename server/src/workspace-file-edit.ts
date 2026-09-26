/**
 * Workspace file editor write contract (I0).
 *
 * Reads and writes share one eligibility predicate that is stricter than
 * host-workspace current-file fallbacks (`~`, host-absolute, `..`).
 *
 * Atomic rename is not compare-and-swap against agent, git, or shell writers.
 * An in-process mutex serializes editor PUTs for the same canonical file.
 * Rename and temp cleanup are path operations, not inode-safe. A same-host
 * writer that swaps the temp name after the last inode and byte check, or
 * between cleanup's lstat and unlink, is an accepted residual race.
 */

import { createHash, randomBytes } from "node:crypto";
import { constants } from "node:fs";
import * as fs from "node:fs/promises";
import type { FileHandle } from "node:fs/promises";
import type { IncomingMessage } from "node:http";
import { dirname, isAbsolute, join } from "node:path";

import { isWorkspaceEditorTextPath, MAX_WORKSPACE_FILE_EDIT_BYTES } from "./file-serving-policy.js";
import { isPathWithinRoot } from "./git-utils.js";
import type { Workspace, WorkspaceFileEditWriteResponse } from "./types.js";
import { resolveWorkspaceUserPath } from "./workspace-user-path.js";

export const WORKSPACE_FILE_EDIT_MAX_BYTES = MAX_WORKSPACE_FILE_EDIT_BYTES;

const IF_MATCH_RE = /^"sha256-[0-9a-f]{64}"$/;
const TEMP_PREFIX = ".oppi-edit-";
const TEMP_SUFFIX = ".tmp";
const TEMP_OPEN_FLAGS =
  constants.O_RDWR | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW;

type CapturedTemp = {
  path: string;
  dev: number;
  ino: number;
};

export type WorkspaceFileEditInspection =
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
  | { kind: "not-found" }
  | { kind: "forbidden" }
  | { kind: "ineligible" };

export type PutWorkspaceFileResult =
  | { kind: "ok"; response: WorkspaceFileEditWriteResponse }
  | { kind: "error"; status: number; message: string };

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

function editorPathForm(workspace: Workspace, requestedPath: string): "ok" | "ineligible" {
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
  if (workspace.runtime === "sandbox" && normalized.startsWith("/workspace/")) {
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

function inspectionError(inspection: WorkspaceFileEditInspection): PutWorkspaceFileResult | null {
  if (inspection.kind === "eligible") return null;
  if (inspection.kind === "forbidden") {
    return { kind: "error", status: 403, message: "Path outside sandbox workspace" };
  }
  return { kind: "error", status: 404, message: "File not found" };
}

/**
 * Shared editor eligibility. Stricter than host-workspace current-file reads:
 * no `~`, host-absolute, or `..` fallback, no final-component symlink, at most
 * 1 MiB, editor text types only, valid UTF-8, no NUL. Callers map `ineligible`
 * to "no ETag" on GET and existing 404 on PUT. Sandbox escape stays 403.
 */
export async function inspectWorkspaceFileForEdit(input: {
  workspace: Workspace;
  root: string;
  requestedPath: string;
  dataDir: string;
}): Promise<WorkspaceFileEditInspection> {
  if (editorPathForm(input.workspace, input.requestedPath) !== "ok") {
    return { kind: "ineligible" };
  }

  const lexicalPath = resolveWorkspaceUserPath({
    workspace: input.workspace,
    requestedPath: input.requestedPath,
    hostMount: input.root,
    dataDir: input.dataDir,
  });
  if (!lexicalPath) {
    return input.workspace.runtime === "sandbox" ? { kind: "forbidden" } : { kind: "not-found" };
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
  } catch {
    return { kind: "not-found" };
  }

  let canonical: string;
  try {
    canonical = await fs.realpath(lexicalPath);
  } catch {
    return { kind: "not-found" };
  }
  if (!isPathWithinRoot(canonical, realRoot)) {
    return input.workspace.runtime === "sandbox" ? { kind: "forbidden" } : { kind: "ineligible" };
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
      return input.workspace.runtime === "sandbox" ? { kind: "forbidden" } : { kind: "ineligible" };
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

async function writeWorkspaceFileAtomic(input: {
  workspace: Workspace;
  root: string;
  requestedPath: string;
  dataDir: string;
  realPath: string;
  realRoot: string;
  expectedEtag: string;
  bytes: Buffer;
  mode: number;
}): Promise<PutWorkspaceFileResult> {
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
      return input.workspace.runtime === "sandbox"
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
          return input.workspace.runtime === "sandbox"
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

    const recheck = await inspectWorkspaceFileForEdit({
      workspace: input.workspace,
      root: input.root,
      requestedPath: input.requestedPath,
      dataDir: input.dataDir,
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

export async function putWorkspaceFile(input: {
  workspace: Workspace;
  root: string;
  requestedPath: string;
  dataDir: string;
  ifMatch: string | string[] | undefined;
  body: Buffer;
}): Promise<PutWorkspaceFileResult> {
  const precondition = evaluateIfMatch(input.ifMatch);
  if (precondition.kind === "missing") {
    return { kind: "error", status: 428, message: "If-Match precondition required" };
  }
  if (precondition.kind === "wildcard" || precondition.kind === "invalid") {
    return { kind: "error", status: 412, message: "Precondition failed" };
  }
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

  const first = await inspectWorkspaceFileForEdit(input);
  const firstError = inspectionError(first);
  if (firstError) return firstError;
  if (first.kind !== "eligible") {
    return { kind: "error", status: 404, message: "File not found" };
  }

  const lockKey = `${input.workspace.id}\0${first.realPath}`;
  return withEditorWriteLock(lockKey, async () => {
    const inspection = await inspectWorkspaceFileForEdit(input);
    const error = inspectionError(inspection);
    if (error) return error;
    if (inspection.kind !== "eligible") {
      return { kind: "error", status: 404, message: "File not found" };
    }
    if (inspection.etag !== precondition.etag || inspection.realPath !== first.realPath) {
      return { kind: "error", status: 412, message: "Precondition failed" };
    }
    return writeWorkspaceFileAtomic({
      workspace: input.workspace,
      root: input.root,
      requestedPath: input.requestedPath,
      dataDir: input.dataDir,
      realPath: inspection.realPath,
      realRoot: inspection.realRoot,
      expectedEtag: precondition.etag,
      bytes: input.body,
      mode: inspection.mode,
    });
  });
}
