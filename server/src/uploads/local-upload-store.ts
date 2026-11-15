import { createHash, randomBytes } from "node:crypto";
import { createWriteStream, existsSync } from "node:fs";
import {
  lstat,
  mkdir,
  readFile,
  readdir,
  rename,
  rm,
  stat,
  statfs,
  writeFile,
} from "node:fs/promises";
import { basename, dirname, extname, join } from "node:path";
import type { IncomingMessage } from "node:http";
import { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";

import { HttpStatusError } from "../http-status-error.js";
import type { AttachmentKind, ChatAttachmentRef, ServerConfig } from "../types.js";

export interface UploadRecord {
  id: string;
  workspaceId?: string;
  sessionId?: string;
  status: "created" | "complete" | "failed" | "expired";
  originalName: string;
  safeName: string;
  declaredMimeType?: string;
  detectedMimeType?: string;
  mimeType: string;
  kind: AttachmentKind;
  declaredSizeBytes: number;
  sizeBytes?: number;
  sha256?: string;
  blobPath?: string;
  purpose: "chat_attachment";
  createdAt: number;
  updatedAt: number;
  completedAt?: number;
  usedAt?: number;
  expiresAt: number;
}

export interface UploadStoreConfigResolved {
  rootPath: string;
  /** Owner-set cap on one file; absent means only free disk space limits it. */
  maxFileBytes?: number;
  /** Owner-set cap on one turn's attachments; absent means no cap. */
  maxTurnBytes?: number;
  unusedTtlMs: number;
  retainedTtlMs: number;
  allowedMimeTypes: string[];
}

export interface UploadStoreGcResult {
  removedRecords: number;
  removedTmpFiles: number;
  removedBlobs: number;
}

const ORPHAN_BLOB_GC_GRACE_MS = 5 * 60 * 1000;

/**
 * A content PUT that sends nothing for this long is a dead connection (the phone lost its
 * network without a reset). Its socket closes, the partial file goes, and the phone's
 * retry starts a fresh upload. Long uploads that keep sending never hit it.
 */
const UPLOAD_IDLE_TIMEOUT_MS = 2 * 60 * 1000;

const GIB = 1024 * 1024 * 1024;

export class UploadStoreError extends HttpStatusError {}

/**
 * Free space an upload must leave on the upload store's volume: 2 GiB or 5% of the
 * volume, whichever is larger. Uploads have no fixed size limit; this keeps a large one
 * from filling the disk the server, its sessions, and the system need.
 */
export function uploadDiskReserveBytes(volumeBytes: number): number {
  return Math.max(2 * GIB, Math.ceil(volumeBytes * 0.05));
}

function formatBytes(bytes: number): string {
  if (bytes >= GIB) return `${(bytes / GIB).toFixed(1)} GB`;
  if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${bytes} bytes`;
}

/** 507 when writing `sizeBytes` would leave less than the reserve free on the store's volume. */
async function assertDiskSpaceFor(rootPath: string, sizeBytes: number): Promise<void> {
  const volume = await statfs(rootPath);
  const availableBytes = volume.bavail * volume.bsize;
  const reserveBytes = uploadDiskReserveBytes(volume.blocks * volume.bsize);
  if (sizeBytes <= availableBytes - reserveBytes) return;
  throw new UploadStoreError(
    507,
    `Not enough free disk space on the server for this ${formatBytes(sizeBytes)} upload: ` +
      `${formatBytes(availableBytes)} free, and uploads always leave ${formatBytes(reserveBytes)} free.`,
  );
}

function isNoSpaceError(error: unknown): boolean {
  return (error as NodeJS.ErrnoException | undefined)?.code === "ENOSPC";
}

function fileCapError(maxFileBytes: number): UploadStoreError {
  return new UploadStoreError(
    413,
    `Upload exceeds this server's ${formatBytes(maxFileBytes)} file size limit (uploadStore.maxFileBytes)`,
  );
}

function sanitizeFileName(name: string): string {
  const base = basename(name || "").trim();
  let cleaned = "";
  for (const char of base) {
    const code = char.charCodeAt(0);
    if (code <= 31 || code === 127 || char === "/" || char === "\\") {
      continue;
    }
    cleaned += char;
  }
  return cleaned.length > 0 ? cleaned.slice(0, 120) : "attachment";
}

function classifyFromMime(mimeType: string): AttachmentKind {
  if (mimeType.startsWith("image/")) return "image";
  if (mimeType.startsWith("audio/")) return "audio";
  if (mimeType.startsWith("video/")) return "video";
  if (mimeType === "application/pdf") return "pdf";
  if (
    mimeType.startsWith("text/") ||
    mimeType === "application/json" ||
    mimeType === "application/xml"
  ) {
    return "text";
  }
  if (
    mimeType === "application/zip" ||
    mimeType === "application/gzip" ||
    mimeType === "application/x-tar"
  ) {
    return "archive";
  }
  return "unknown";
}

function normalizeMimeType(mimeType: string | undefined): string {
  const normalized = mimeType?.split(";", 1)[0]?.trim().toLowerCase() ?? "";
  return normalized || "application/octet-stream";
}

function normalizeAllowedMimeTypes(mimeTypes: string[] | undefined): string[] {
  if (!mimeTypes?.length) {
    return [];
  }

  const seen = new Set<string>();
  const normalized: string[] = [];
  for (const value of mimeTypes) {
    const mimeType = normalizeMimeType(value);
    if (seen.has(mimeType)) {
      continue;
    }
    seen.add(mimeType);
    normalized.push(mimeType);
  }
  return normalized;
}

function validateAllowedMimeType(
  config: UploadStoreConfigResolved,
  mimeType: string | undefined,
  phase: "Declared" | "Detected",
): string {
  const normalized = normalizeMimeType(mimeType);
  if (config.allowedMimeTypes.length === 0) {
    return normalized;
  }
  if (config.allowedMimeTypes.includes(normalized)) {
    return normalized;
  }
  throw new UploadStoreError(415, `${phase} MIME type not allowed: ${normalized}`);
}

function isUploadExpired(record: UploadRecord, now = Date.now()): boolean {
  if (record.status === "complete" && record.usedAt) {
    return false;
  }
  return record.expiresAt <= now;
}

const SNIFFED_BINARY_MIME_TYPES = new Set([
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
  "application/pdf",
  "application/zip",
  "application/gzip",
]);

function detectMimeType(header: Buffer, declaredMimeType?: string, name?: string): string {
  if (
    header.length >= 8 &&
    header.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
  ) {
    return "image/png";
  }
  if (header.length >= 3 && header[0] === 0xff && header[1] === 0xd8 && header[2] === 0xff) {
    return "image/jpeg";
  }
  if (header.length >= 6 && header.subarray(0, 6).toString("ascii") === "GIF87a") {
    return "image/gif";
  }
  if (header.length >= 6 && header.subarray(0, 6).toString("ascii") === "GIF89a") {
    return "image/gif";
  }
  if (
    header.length >= 12 &&
    header.subarray(0, 4).toString("ascii") === "RIFF" &&
    header.subarray(8, 12).toString("ascii") === "WEBP"
  ) {
    return "image/webp";
  }
  if (header.length >= 5 && header.subarray(0, 5).toString("ascii") === "%PDF-") {
    return "application/pdf";
  }
  if (
    header.length >= 4 &&
    header[0] === 0x50 &&
    header[1] === 0x4b &&
    header[2] === 0x03 &&
    header[3] === 0x04
  ) {
    return "application/zip";
  }
  if (header.length >= 2 && header[0] === 0x1f && header[1] === 0x8b) {
    return "application/gzip";
  }
  const ext = extname(name ?? "").toLowerCase();
  const normalizedDeclaredMimeType = normalizeMimeType(declaredMimeType);
  if (
    (ext === ".heic" || ext === ".heif") &&
    normalizedDeclaredMimeType !== "application/octet-stream"
  ) {
    return normalizedDeclaredMimeType;
  }
  if (SNIFFED_BINARY_MIME_TYPES.has(normalizedDeclaredMimeType)) {
    return "application/octet-stream";
  }
  return normalizedDeclaredMimeType;
}

function blobPathFor(rootPath: string, sha256: string): string {
  return join(rootPath, "blobs", "sha256", sha256.slice(0, 2), sha256.slice(2, 4), sha256);
}

function recordPathFor(rootPath: string, uploadId: string): string {
  return join(rootPath, "records", `${uploadId}.json`);
}

/** Each content PUT writes its own partial file, so a retry never shares one with a dying attempt. */
function tmpPathFor(rootPath: string, uploadId: string): string {
  return join(rootPath, "tmp", `${uploadId}.${randomBytes(4).toString("hex")}.part`);
}

/**
 * Partial files of content PUTs running in this process. Garbage collection keeps these and
 * removes every other partial file: a failed PUT deletes its own, so the rest are leftovers
 * of a crash.
 */
const writingTmpPaths = new Set<string>();

/**
 * Uploads with a content PUT running. A created upload nothing writes to for an hour was
 * abandoned (the phone gave up and created a new one); garbage collection removes it then
 * rather than at its 24-hour expiry.
 */
const writingUploadIds = new Map<string, number>();
const ABANDONED_CREATED_UPLOAD_MS = 60 * 60 * 1000;

async function ensureDirs(rootPath: string): Promise<void> {
  await mkdir(join(rootPath, "records"), { recursive: true });
  await mkdir(join(rootPath, "tmp"), { recursive: true });
  await mkdir(join(rootPath, "blobs", "sha256"), { recursive: true });
}

async function writeRecord(rootPath: string, record: UploadRecord): Promise<void> {
  await ensureDirs(rootPath);
  await writeFile(
    recordPathFor(rootPath, record.id),
    `${JSON.stringify(record, null, 2)}\n`,
    "utf8",
  );
}

async function rmIfExists(path: string): Promise<boolean> {
  try {
    await lstat(path);
  } catch {
    return false;
  }

  try {
    await rm(path, { force: true, recursive: false });
    return true;
  } catch {
    return false;
  }
}

async function isOlderThan(path: string, now: number, ageMs: number): Promise<boolean> {
  const info = await lstat(path).catch(() => null);
  if (!info) {
    return false;
  }
  return info.mtimeMs <= now - ageMs;
}

async function collectFiles(rootPath: string): Promise<string[]> {
  let entries: string[];
  try {
    entries = await readdir(rootPath);
  } catch {
    return [];
  }

  const paths: string[] = [];
  for (const entry of entries) {
    const absolutePath = join(rootPath, entry);
    const info = await lstat(absolutePath).catch(() => null);
    if (!info || info.isSymbolicLink()) {
      continue;
    }
    if (info.isDirectory()) {
      paths.push(...(await collectFiles(absolutePath)));
      continue;
    }
    if (info.isFile()) {
      paths.push(absolutePath);
    }
  }
  return paths;
}

export function resolveUploadStoreConfig(config: ServerConfig): UploadStoreConfigResolved {
  const rootPath = config.uploadStore?.path?.trim() || join(config.dataDir, "uploads");
  const unusedTtlMs = config.uploadStore?.unusedTtlMs ?? 24 * 60 * 60 * 1000;
  return {
    rootPath,
    maxFileBytes: config.uploadStore?.maxFileBytes,
    maxTurnBytes: config.uploadStore?.maxTurnBytes,
    unusedTtlMs,
    retainedTtlMs: config.uploadStore?.retainedTtlMs ?? unusedTtlMs,
    allowedMimeTypes: normalizeAllowedMimeTypes(config.uploadStore?.allowedMimeTypes),
  };
}

export async function createUploadRecord(args: {
  config: UploadStoreConfigResolved;
  workspaceId?: string;
  sessionId?: string;
  name: string;
  mimeType: string;
  sizeBytes: number;
  purpose: string;
}): Promise<UploadRecord> {
  if (args.purpose !== "chat_attachment") {
    throw new UploadStoreError(400, "purpose must be chat_attachment");
  }
  if (!Number.isInteger(args.sizeBytes) || args.sizeBytes <= 0) {
    throw new UploadStoreError(400, "sizeBytes must be a positive integer");
  }
  if (args.config.maxFileBytes !== undefined && args.sizeBytes > args.config.maxFileBytes) {
    throw fileCapError(args.config.maxFileBytes);
  }
  const safeName = sanitizeFileName(args.name);
  if (!safeName) {
    throw new UploadStoreError(400, "name required");
  }

  const declaredMimeType = validateAllowedMimeType(args.config, args.mimeType, "Declared");
  await ensureDirs(args.config.rootPath);
  await assertDiskSpaceFor(args.config.rootPath, args.sizeBytes);
  const now = Date.now();
  const id = `upl_${randomBytes(9).toString("hex")}`;
  const record: UploadRecord = {
    id,
    ...(args.workspaceId ? { workspaceId: args.workspaceId } : {}),
    ...(args.sessionId ? { sessionId: args.sessionId } : {}),
    status: "created",
    originalName: args.name,
    safeName,
    declaredMimeType,
    mimeType: declaredMimeType,
    kind: classifyFromMime(declaredMimeType),
    declaredSizeBytes: args.sizeBytes,
    purpose: "chat_attachment",
    createdAt: now,
    updatedAt: now,
    expiresAt: now + args.config.unusedTtlMs,
  };

  await writeRecord(args.config.rootPath, record);
  return record;
}

export async function getUploadRecord(
  config: UploadStoreConfigResolved,
  uploadId: string,
): Promise<UploadRecord | null> {
  try {
    const content = await readFile(recordPathFor(config.rootPath, uploadId), "utf8");
    return JSON.parse(content) as UploadRecord;
  } catch {
    return null;
  }
}

export async function writeUploadContent(args: {
  config: UploadStoreConfigResolved;
  workspaceId?: string;
  sessionId?: string;
  uploadId: string;
  req: IncomingMessage;
}): Promise<UploadRecord> {
  const record = await getUploadRecord(args.config, args.uploadId);
  if (!record || record.workspaceId !== args.workspaceId || record.sessionId !== args.sessionId) {
    throw new UploadStoreError(404, "Upload not found");
  }
  if (record.status !== "created") {
    throw new UploadStoreError(409, "Upload is not in created state");
  }
  if (isUploadExpired(record)) {
    throw new UploadStoreError(409, "Upload has expired");
  }

  await ensureDirs(args.config.rootPath);
  // Space may have gone since the upload was created (another upload, a session's files).
  await assertDiskSpaceFor(args.config.rootPath, record.declaredSizeBytes);
  const tmpPath = tmpPathFor(args.config.rootPath, args.uploadId);
  const hash = createHash("sha256");
  const headerChunks: Buffer[] = [];
  let headerBytes = 0;
  let totalBytes = 0;
  const { maxFileBytes } = args.config;
  // Counts, hashes, and caps the body as it passes to disk. `pipeline` holds the request
  // while the disk catches up, so memory stays flat whatever the upload's size.
  const meter = new Transform({
    transform(chunk: Buffer | string, _encoding, callback) {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      totalBytes += buffer.length;
      if (maxFileBytes !== undefined && totalBytes > maxFileBytes) {
        callback(fileCapError(maxFileBytes));
        return;
      }
      // The free-space check covered the declared size; never write past it.
      if (totalBytes > record.declaredSizeBytes) {
        callback(
          new UploadStoreError(
            400,
            `Upload size mismatch: expected ${record.declaredSizeBytes}, got more`,
          ),
        );
        return;
      }
      if (headerBytes < 64) {
        const head = buffer.subarray(0, 64 - headerBytes);
        headerChunks.push(head);
        headerBytes += head.length;
      }
      hash.update(buffer);
      callback(null, buffer);
    },
  });

  const socket = args.req.socket as IncomingMessage["socket"] | undefined;
  const onIdle = (): void => {
    args.req.destroy(new UploadStoreError(408, "Upload stalled"));
  };
  socket?.setTimeout(UPLOAD_IDLE_TIMEOUT_MS, onIdle);
  writingTmpPaths.add(tmpPath);
  writingUploadIds.set(args.uploadId, (writingUploadIds.get(args.uploadId) ?? 0) + 1);
  try {
    await pipeline(args.req, meter, createWriteStream(tmpPath, { flags: "w" }));
  } catch (error) {
    // The upload stays "created": iOS resends a dropped background upload to the same URL,
    // and that PUT starts over in a fresh partial file.
    await rm(tmpPath, { force: true }).catch(() => undefined);
    if (isNoSpaceError(error)) {
      throw new UploadStoreError(507, "The server ran out of disk space during the upload");
    }
    throw error;
  } finally {
    socket?.setTimeout(0);
    socket?.off("timeout", onIdle);
    writingTmpPaths.delete(tmpPath);
    const writers = (writingUploadIds.get(args.uploadId) ?? 1) - 1;
    if (writers > 0) writingUploadIds.set(args.uploadId, writers);
    else writingUploadIds.delete(args.uploadId);
  }

  if (totalBytes !== record.declaredSizeBytes) {
    await rm(tmpPath, { force: true }).catch(() => undefined);
    throw new UploadStoreError(
      400,
      `Upload size mismatch: expected ${record.declaredSizeBytes}, got ${totalBytes}`,
    );
  }

  const declaredMimeType = normalizeMimeType(record.declaredMimeType);
  const detectedMimeType = validateAllowedMimeType(
    args.config,
    detectMimeType(Buffer.concat(headerChunks), record.declaredMimeType, record.safeName),
    "Detected",
  );
  if (declaredMimeType !== "application/octet-stream" && detectedMimeType !== declaredMimeType) {
    await rm(tmpPath, { force: true }).catch(() => undefined);
    throw new UploadStoreError(
      415,
      `Upload MIME type mismatch: declared ${declaredMimeType}, detected ${detectedMimeType}`,
    );
  }

  // Another PUT of the same upload (a resend overlapping the attempt it replaced) got there first.
  const current = await getUploadRecord(args.config, args.uploadId);
  if (current?.status === "complete") {
    await rm(tmpPath, { force: true }).catch(() => undefined);
    return current;
  }

  const sha256 = hash.digest("hex");
  const blobPath = blobPathFor(args.config.rootPath, sha256);
  await mkdir(dirname(blobPath), { recursive: true });
  if (existsSync(blobPath)) {
    await rm(tmpPath, { force: true }).catch(() => undefined);
  } else {
    await rename(tmpPath, blobPath);
  }

  const completedAt = Date.now();
  const updated: UploadRecord = {
    ...record,
    status: "complete",
    detectedMimeType,
    mimeType: detectedMimeType,
    kind: classifyFromMime(detectedMimeType),
    sizeBytes: totalBytes,
    sha256,
    blobPath,
    updatedAt: completedAt,
    completedAt,
    expiresAt: completedAt + args.config.retainedTtlMs,
  };
  await writeRecord(args.config.rootPath, updated);
  return updated;
}

export async function resolveUploadAttachment(args: {
  config: UploadStoreConfigResolved;
  workspaceId?: string;
  sessionId?: string;
  ref: ChatAttachmentRef;
}): Promise<UploadRecord> {
  if (args.ref.source !== "upload") {
    throw new UploadStoreError(400, `Unsupported attachment source: ${args.ref.source}`);
  }
  const record = await getUploadRecord(args.config, args.ref.id);
  if (!record || record.workspaceId !== args.workspaceId || record.sessionId !== args.sessionId) {
    throw new UploadStoreError(404, "Upload not found");
  }
  if (record.status !== "complete" || !record.blobPath || !record.sizeBytes || !record.sha256) {
    throw new UploadStoreError(409, "Upload is not complete");
  }
  if (isUploadExpired(record)) {
    throw new UploadStoreError(409, "Upload has expired");
  }
  const blobStats = await stat(record.blobPath).catch(() => null);
  if (!blobStats?.isFile()) {
    throw new UploadStoreError(409, "Upload blob missing");
  }
  if (args.ref.name && sanitizeFileName(args.ref.name) !== record.safeName) {
    throw new UploadStoreError(409, "Upload name mismatch");
  }
  if (args.ref.mimeType && normalizeMimeType(args.ref.mimeType) !== record.mimeType) {
    throw new UploadStoreError(409, "Upload MIME type mismatch");
  }
  if (args.ref.sizeBytes && args.ref.sizeBytes !== record.sizeBytes) {
    throw new UploadStoreError(409, "Upload size mismatch");
  }
  if (args.ref.sha256 && args.ref.sha256 !== record.sha256) {
    throw new UploadStoreError(409, "Upload hash mismatch");
  }

  if (record.usedAt) {
    return record;
  }

  const updated = {
    ...record,
    usedAt: Date.now(),
    updatedAt: Date.now(),
  } satisfies UploadRecord;
  await writeRecord(args.config.rootPath, updated);
  return updated;
}

export async function garbageCollectUploadStore(
  config: UploadStoreConfigResolved,
  now = Date.now(),
): Promise<UploadStoreGcResult> {
  await ensureDirs(config.rootPath);

  const liveBlobPaths = new Set<string>();
  const recordPaths = await collectFiles(join(config.rootPath, "records"));

  let removedRecords = 0;
  let removedTmpFiles = 0;
  let removedBlobs = 0;

  for (const recordPath of recordPaths) {
    let record: UploadRecord;
    try {
      const content = await readFile(recordPath, "utf8");
      record = JSON.parse(content) as UploadRecord;
    } catch {
      continue;
    }

    const abandoned =
      record.status === "created" &&
      !writingUploadIds.has(record.id) &&
      record.updatedAt <= now - ABANDONED_CREATED_UPLOAD_MS;
    if (isUploadExpired(record, now) || abandoned) {
      if (await rmIfExists(recordPath)) {
        removedRecords += 1;
      }
      continue;
    }

    if (record.blobPath) {
      liveBlobPaths.add(record.blobPath);
    }
  }

  for (const tmpPath of await collectFiles(join(config.rootPath, "tmp"))) {
    if (writingTmpPaths.has(tmpPath)) {
      continue;
    }
    if (await rmIfExists(tmpPath)) {
      removedTmpFiles += 1;
    }
  }

  for (const blobPath of await collectFiles(join(config.rootPath, "blobs"))) {
    if (liveBlobPaths.has(blobPath)) {
      continue;
    }
    if (!(await isOlderThan(blobPath, now, ORPHAN_BLOB_GC_GRACE_MS))) {
      continue;
    }
    if (await rmIfExists(blobPath)) {
      removedBlobs += 1;
    }
  }

  return { removedRecords, removedTmpFiles, removedBlobs };
}

export function uploadRecordToAttachmentRef(record: UploadRecord): ChatAttachmentRef {
  return {
    type: "attachment",
    id: record.id,
    source: "upload",
    name: record.safeName,
    mimeType: record.mimeType,
    sizeBytes: record.sizeBytes ?? record.declaredSizeBytes,
    sha256: record.sha256,
    kind: record.kind,
  };
}
