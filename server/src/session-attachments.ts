import { createHash } from "node:crypto";
import {
  createReadStream,
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { stat } from "node:fs/promises";
import { basename, extname, isAbsolute, join, relative } from "node:path";
import type { ServerResponse } from "node:http";

import { generateId } from "./id.js";

const MANIFEST_VERSION = 1;
const MAX_SESSION_ATTACHMENT_BYTES = 50 * 1024 * 1024;
const DEFAULT_AUDIO_MIME_TYPE = "audio/wav";
const DEFAULT_IMAGE_MIME_TYPE = "image/png";

type SessionAttachmentKind = "audio" | "image";

export interface SessionAttachmentRecord {
  id: string;
  kind: SessionAttachmentKind;
  mimeType: string;
  fileName: string;
  sizeBytes: number;
  storageKey: string;
  createdAt: number;
  toolCallId?: string;
  durationSeconds?: number;
  width?: number;
  height?: number;
  text?: string;
}

interface SessionAttachmentManifest {
  version: 1;
  attachments: SessionAttachmentRecord[];
}

export interface MaterializeToolAudioOptions {
  dataDir: string;
  sessionId: string;
  toolCallId?: string;
  details: unknown;
  /**
   * Explicit roots from which server-side audio paths may be copied.
   * When omitted, audio.path is treated as untrusted metadata and ignored.
   */
  trustedSourceRoots?: string[];
}

export interface MaterializeToolMediaContentOptions {
  dataDir: string;
  sessionId: string;
  toolCallId?: string;
  contents: unknown[];
  fallbackFileName?: string;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function attachmentsRoot(dataDir: string): string {
  return join(dataDir, "session-attachments");
}

function sessionDir(dataDir: string, sessionId: string): string {
  return join(attachmentsRoot(dataDir), sessionId);
}

function manifestPath(dataDir: string, sessionId: string): string {
  return join(sessionDir(dataDir, sessionId), "manifest.json");
}

function readManifest(dataDir: string, sessionId: string): SessionAttachmentManifest {
  const path = manifestPath(dataDir, sessionId);
  if (!existsSync(path)) {
    return { version: MANIFEST_VERSION, attachments: [] };
  }
  const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<SessionAttachmentManifest>;
  if (!parsed || !Array.isArray(parsed.attachments)) {
    throw new Error(`Invalid session attachment manifest: ${path}`);
  }
  return {
    version: MANIFEST_VERSION,
    attachments: parsed.attachments,
  };
}

function writeManifest(
  dataDir: string,
  sessionId: string,
  manifest: SessionAttachmentManifest,
): void {
  mkdirSync(sessionDir(dataDir, sessionId), { recursive: true, mode: 0o700 });
  writeFileSync(manifestPath(dataDir, sessionId), JSON.stringify(manifest, null, 2), {
    mode: 0o600,
  });
}

function mimeExtension(mimeType: string, fallbackFileName?: string): string {
  const fallbackExt = fallbackFileName ? extname(fallbackFileName).replace(/^\./, "") : "";
  if (fallbackExt) return fallbackExt;
  switch (mimeType.toLowerCase()) {
    case "audio/wav":
    case "audio/wave":
    case "audio/x-wav":
      return "wav";
    case "audio/mpeg":
      return "mp3";
    case "audio/mp4":
      return "m4a";
    case "audio/flac":
      return "flac";
    case "audio/ogg":
      return "ogg";
    case "audio/opus":
      return "opus";
    case "image/png":
      return "png";
    case "image/jpeg":
    case "image/jpg":
      return "jpg";
    case "image/gif":
      return "gif";
    case "image/webp":
      return "webp";
    case "image/svg+xml":
      return "svg";
    case "image/bmp":
      return "bmp";
    case "image/tiff":
      return "tiff";
    default:
      return "bin";
  }
}

function defaultFileStem(kind: SessionAttachmentKind): string {
  return kind === "image" ? "tool-image" : "tool-audio";
}

function normalizeAudioMimeType(value: unknown): string {
  const mimeType = typeof value === "string" ? value.trim().toLowerCase() : "";
  return mimeType.startsWith("audio/") ? mimeType : DEFAULT_AUDIO_MIME_TYPE;
}

function normalizeImageMimeType(value: unknown): string {
  const mimeType = typeof value === "string" ? value.trim().toLowerCase() : "";
  return mimeType.startsWith("image/") ? mimeType : DEFAULT_IMAGE_MIME_TYPE;
}

function safeFileName(
  value: unknown,
  mimeType: string,
  kind: SessionAttachmentKind = "audio",
): string {
  const raw =
    typeof value === "string" && value.trim() ? basename(value.trim()) : defaultFileStem(kind);
  const ext = extname(raw) ? "" : `.${mimeExtension(mimeType)}`;
  return `${raw}${ext}`;
}

function isPathInsideRoot(path: string, root: string): boolean {
  const relation = relative(root, path);
  return relation === "" || (!!relation && !relation.startsWith("..") && !isAbsolute(relation));
}

function bytesFromTrustedPath(
  path: string,
  trustedSourceRoots: string[] | undefined,
): Buffer | null {
  if (!trustedSourceRoots || trustedSourceRoots.length === 0) return null;

  try {
    const realPath = realpathSync(path);
    const allowed = trustedSourceRoots.some((root) => {
      try {
        return isPathInsideRoot(realPath, realpathSync(root));
      } catch {
        return false;
      }
    });
    if (!allowed) return null;

    const info = statSync(realPath);
    if (!info.isFile() || info.size <= 0 || info.size > MAX_SESSION_ATTACHMENT_BYTES) return null;
    return readFileSync(realPath);
  } catch {
    return null;
  }
}

function bytesFromAudioDetails(
  audio: Record<string, unknown>,
  trustedSourceRoots: string[] | undefined,
): Buffer | null {
  const path = typeof audio.path === "string" ? audio.path : undefined;
  if (path) {
    const bytes = bytesFromTrustedPath(path, trustedSourceRoots);
    if (bytes) return bytes;
  }

  const base64 = typeof audio.base64 === "string" ? audio.base64.trim() : "";
  if (!base64) return null;
  const bytes = Buffer.from(base64, "base64");
  if (bytes.length <= 0 || bytes.length > MAX_SESSION_ATTACHMENT_BYTES) return null;
  return bytes;
}

function attachmentIdFor(toolCallId: string | undefined, bytes: Buffer): string {
  const digest = createHash("sha256").update(bytes).digest("base64url").slice(0, 16);
  if (toolCallId) return `att_${toolCallId.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 32)}_${digest}`;
  return `att_${generateId(12)}_${digest}`;
}

function base64FromMediaRecord(media: Record<string, unknown>): string | undefined {
  const raw =
    typeof media.base64 === "string"
      ? media.base64.trim()
      : typeof media.data === "string"
        ? media.data.trim()
        : "";
  return raw ? raw : undefined;
}

function sanitizeMediaDetails(
  root: Record<string, unknown>,
  key: "audio" | "image",
  media: Record<string, unknown>,
  options: { preserveBase64?: boolean } = {},
): Record<string, unknown> {
  const sanitized = { ...media } as Record<string, unknown>;
  const preservedBase64 = options.preserveBase64 ? base64FromMediaRecord(media) : undefined;
  delete sanitized.base64;
  delete sanitized.data;
  delete sanitized.path;
  if (preservedBase64) {
    sanitized.base64 = preservedBase64;
  }
  return { ...root, [key]: sanitized };
}

function imageDimensions(
  bytes: Buffer,
  mimeType: string,
): { width: number; height: number } | undefined {
  if (
    bytes.length >= 24 &&
    bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
  ) {
    const width = bytes.readUInt32BE(16);
    const height = bytes.readUInt32BE(20);
    return width > 0 && height > 0 ? { width, height } : undefined;
  }

  if (bytes.length >= 10 && bytes.subarray(0, 3).toString("ascii") === "GIF") {
    const width = bytes.readUInt16LE(6);
    const height = bytes.readUInt16LE(8);
    return width > 0 && height > 0 ? { width, height } : undefined;
  }

  if (bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    let offset = 2;
    while (offset + 9 < bytes.length) {
      if (bytes[offset] !== 0xff) {
        offset += 1;
        continue;
      }
      const marker = bytes[offset + 1];
      const length = bytes.readUInt16BE(offset + 2);
      if (length < 2 || offset + 2 + length > bytes.length) break;
      const isSOF =
        (marker >= 0xc0 && marker <= 0xc3) ||
        (marker >= 0xc5 && marker <= 0xc7) ||
        (marker >= 0xc9 && marker <= 0xcb) ||
        (marker >= 0xcd && marker <= 0xcf);
      if (isSOF && offset + 8 < bytes.length) {
        const height = bytes.readUInt16BE(offset + 5);
        const width = bytes.readUInt16BE(offset + 7);
        return width > 0 && height > 0 ? { width, height } : undefined;
      }
      offset += 2 + length;
    }
  }

  if (mimeType === "image/svg+xml") {
    const text = bytes.subarray(0, Math.min(bytes.length, 8192)).toString("utf8");
    const viewBox = text.match(/viewBox\s*=\s*["']?[-\d.]+\s+[-\d.]+\s+([\d.]+)\s+([\d.]+)/i);
    const width = viewBox ? Number(viewBox[1]) : undefined;
    const height = viewBox ? Number(viewBox[2]) : undefined;
    if (width && height && width > 0 && height > 0) return { width, height };
  }

  return undefined;
}

function attachmentDetails(record: SessionAttachmentRecord): Record<string, unknown> {
  return {
    kind: record.kind,
    id: record.id,
    mimeType: record.mimeType,
    fileName: record.fileName,
    sizeBytes: record.sizeBytes,
    storageKey: record.storageKey,
    ...(record.durationSeconds !== undefined ? { durationSeconds: record.durationSeconds } : {}),
    ...(record.width !== undefined ? { width: record.width } : {}),
    ...(record.height !== undefined ? { height: record.height } : {}),
  };
}

function imageAttachmentDetails(
  record: SessionAttachmentRecord,
  media: Record<string, unknown>,
): Record<string, unknown> {
  return {
    ...attachmentDetails(record),
    ...(base64FromMediaRecord(media) ? { base64: base64FromMediaRecord(media) } : {}),
  };
}

function storeAttachment(options: {
  dataDir: string;
  sessionId: string;
  toolCallId?: string;
  kind: SessionAttachmentKind;
  mimeType: string;
  fileName: string;
  bytes: Buffer;
  durationSeconds?: number;
  text?: string;
}): SessionAttachmentRecord {
  const { dataDir, sessionId, toolCallId, kind, mimeType, fileName, bytes } = options;
  const id = attachmentIdFor(toolCallId, bytes);
  const extension = mimeExtension(mimeType, fileName);
  const storageKey = `${sessionId}/${id}.${extension}`;
  const dir = sessionDir(dataDir, sessionId);
  const filePath = join(dir, `${id}.${extension}`);

  mkdirSync(dir, { recursive: true, mode: 0o700 });
  if (!existsSync(filePath)) {
    writeFileSync(filePath, bytes, { mode: 0o600 });
  }

  const dimensions = kind === "image" ? imageDimensions(bytes, mimeType) : undefined;
  const record: SessionAttachmentRecord = {
    id,
    kind,
    mimeType,
    fileName,
    sizeBytes: bytes.length,
    storageKey,
    createdAt: Date.now(),
    ...(toolCallId ? { toolCallId } : {}),
    ...(options.durationSeconds !== undefined ? { durationSeconds: options.durationSeconds } : {}),
    ...(dimensions ? { width: dimensions.width, height: dimensions.height } : {}),
    ...(options.text !== undefined ? { text: options.text } : {}),
  };

  const manifest = readManifest(dataDir, sessionId);
  const existingIndex = manifest.attachments.findIndex((item) => item.id === id);
  if (existingIndex >= 0) {
    manifest.attachments[existingIndex] = { ...manifest.attachments[existingIndex], ...record };
  } else {
    manifest.attachments.push(record);
  }
  writeManifest(dataDir, sessionId, manifest);
  return record;
}

export function materializeToolAudioDetails(options: MaterializeToolAudioOptions): unknown {
  return materializeToolMediaDetails(options);
}

export function materializeToolMediaDetails({
  dataDir,
  sessionId,
  toolCallId,
  details,
  trustedSourceRoots,
}: MaterializeToolAudioOptions): unknown {
  const root = asRecord(details);
  if (!root) return details;

  const audio = asRecord(root.audio);
  let nextRoot: Record<string, unknown> = root;
  if (audio?.kind === "audio") {
    if (typeof audio.id === "string" && audio.id.trim()) {
      nextRoot = sanitizeMediaDetails(nextRoot, "audio", audio);
    } else {
      const bytes = bytesFromAudioDetails(audio, trustedSourceRoots);
      if (!bytes) {
        nextRoot = sanitizeMediaDetails(nextRoot, "audio", audio);
      } else {
        const mimeType = normalizeAudioMimeType(audio.mimeType);
        const record = storeAttachment({
          dataDir,
          sessionId,
          toolCallId,
          kind: "audio",
          mimeType,
          fileName: safeFileName(audio.fileName ?? audio.path, mimeType, "audio"),
          bytes,
          ...(typeof audio.durationSeconds === "number"
            ? { durationSeconds: audio.durationSeconds }
            : {}),
          ...(typeof root.message === "string" ? { text: root.message } : {}),
        });
        nextRoot = { ...nextRoot, audio: attachmentDetails(record) };
      }
    }
  }

  const image = asRecord(root.image);
  if (image?.kind === "image") {
    if (typeof image.id === "string" && image.id.trim()) {
      nextRoot = sanitizeMediaDetails(nextRoot, "image", image, { preserveBase64: true });
    } else {
      const bytes = bytesFromImageLike(image);
      if (!bytes) {
        nextRoot = sanitizeMediaDetails(nextRoot, "image", image, { preserveBase64: true });
      } else {
        const mimeType = normalizeImageMimeType(image.mimeType);
        const record = storeAttachment({
          dataDir,
          sessionId,
          toolCallId,
          kind: "image",
          mimeType,
          fileName: safeFileName(image.fileName ?? image.path, mimeType, "image"),
          bytes,
          ...(typeof root.message === "string" ? { text: root.message } : {}),
        });
        nextRoot = { ...nextRoot, image: imageAttachmentDetails(record, image) };
      }
    }
  }

  return nextRoot;
}

function bytesFromImageLike(image: Record<string, unknown>): Buffer | null {
  // Image attachments intentionally do not materialize arbitrary server-side
  // paths. Built-in read/screenshot tools should provide bytes in the media
  // block; serving later happens only from the copied session-attachment store.
  const base64 = base64FromMediaRecord(image) ?? "";
  if (!base64) return null;
  const bytes = Buffer.from(base64, "base64");
  if (bytes.length <= 0 || bytes.length > MAX_SESSION_ATTACHMENT_BYTES) return null;
  return bytes;
}

export function materializeToolMediaContentBlocks({
  dataDir,
  sessionId,
  toolCallId,
  contents,
  fallbackFileName,
}: MaterializeToolMediaContentOptions): unknown[] {
  return contents.map((block, index) => {
    const record = asRecord(block);
    if (!record || record.type !== "image" || typeof record.data !== "string") {
      return block;
    }

    const bytes = bytesFromImageLike(record);
    if (!bytes) {
      const sanitized = { ...record };
      delete sanitized.data;
      return sanitized;
    }

    const mimeType = normalizeImageMimeType(record.mimeType);
    const fileName = safeFileName(
      record.fileName ?? fallbackFileName ?? `tool-image-${index + 1}`,
      mimeType,
      "image",
    );
    const attachment = storeAttachment({
      dataDir,
      sessionId,
      toolCallId,
      kind: "image",
      mimeType,
      fileName,
      bytes,
    });

    return {
      type: "image",
      ...attachmentDetails(attachment),
    };
  });
}

function attachmentIdFromMediaRecord(
  toolCallId: string | undefined,
  media: Record<string, unknown>,
): string | undefined {
  const existingId = typeof media.id === "string" ? media.id.trim() : "";
  if (existingId) {
    return existingId;
  }

  if (!toolCallId) {
    return undefined;
  }

  const bytes =
    media.kind === "audio" ? bytesFromAudioDetails(media, undefined) : bytesFromImageLike(media);
  return bytes ? attachmentIdFor(toolCallId, bytes) : undefined;
}

function findAttachmentRecordForMedia(
  manifest: SessionAttachmentManifest,
  toolCallId: string,
  key: "audio" | "image",
  media: Record<string, unknown>,
): SessionAttachmentRecord | undefined {
  const explicitId = attachmentIdFromMediaRecord(toolCallId, media);
  if (explicitId) {
    const byId = manifest.attachments.find((item) => item.id === explicitId && item.kind === key);
    if (byId) {
      return byId;
    }
  }

  return manifest.attachments.find((item) => item.toolCallId === toolCallId && item.kind === key);
}

function mediaDetailsForReplayRecord(
  record: SessionAttachmentRecord,
  key: "audio" | "image",
  media: Record<string, unknown>,
): Record<string, unknown> {
  return key === "image" ? imageAttachmentDetails(record, media) : attachmentDetails(record);
}

function referencedAttachmentIdsFromContents(
  contents: unknown,
  toolCallId: string | undefined,
): Set<string> {
  const ids = new Set<string>();
  if (!Array.isArray(contents)) {
    return ids;
  }

  for (const block of contents) {
    const record = asRecord(block);
    if (!record) continue;
    const type = record.type;
    if (type !== "image" && type !== "audio" && type !== "output_audio") {
      continue;
    }
    const id = attachmentIdFromMediaRecord(toolCallId, {
      ...record,
      kind: type === "image" ? "image" : "audio",
    });
    if (id) {
      ids.add(id);
    }
  }

  return ids;
}

function referencedAttachmentIdsFromDetails(
  details: unknown,
  toolCallId: string | undefined,
): Set<string> {
  const ids = new Set<string>();
  const root = asRecord(details);
  if (!root) {
    return ids;
  }

  for (const key of ["audio", "image"] as const) {
    const media = asRecord(root[key]);
    if (!media || media.kind !== key) continue;
    const id = attachmentIdFromMediaRecord(toolCallId, media);
    if (id) {
      ids.add(id);
    }
  }

  const mediaArray = Array.isArray(root.media) ? root.media : [];
  for (const entry of mediaArray) {
    const media = asRecord(entry);
    if (!media) continue;
    const id = attachmentIdFromMediaRecord(toolCallId, media);
    if (id) {
      ids.add(id);
    }
  }

  return ids;
}

export function sessionAttachmentDetailsForToolCall(
  dataDir: string,
  sessionId: string,
  toolCallId: string | undefined,
  details: unknown,
): unknown {
  if (!toolCallId) return details;
  const root = asRecord(details);
  if (!root) return details;

  const manifest = readManifest(dataDir, sessionId);
  let nextRoot: Record<string, unknown> = root;

  for (const key of ["audio", "image"] as const) {
    const media = asRecord(root[key]);
    if (!media || media.kind !== key) continue;
    const record = findAttachmentRecordForMedia(manifest, toolCallId, key, media);
    nextRoot = record
      ? { ...nextRoot, [key]: mediaDetailsForReplayRecord(record, key, media) }
      : sanitizeMediaDetails(nextRoot, key, media, { preserveBase64: key === "image" });
  }

  return nextRoot;
}

export function sessionAttachmentMediaDetailsForToolCall(
  dataDir: string,
  sessionId: string,
  toolCallId: string | undefined,
): Record<string, unknown>[] {
  if (!toolCallId) return [];
  const manifest = readManifest(dataDir, sessionId);
  return manifest.attachments
    .filter((item) => item.toolCallId === toolCallId)
    .map(attachmentDetails);
}

export function sessionAttachmentMediaDetailsForToolResult(
  dataDir: string,
  sessionId: string,
  toolCallId: string | undefined,
  content: unknown,
  details?: unknown,
): Record<string, unknown>[] {
  if (!toolCallId) return [];
  const ids = new Set<string>([
    ...referencedAttachmentIdsFromContents(content, toolCallId),
    ...referencedAttachmentIdsFromDetails(details, toolCallId),
  ]);
  if (ids.size === 0) {
    return [];
  }

  const manifest = readManifest(dataDir, sessionId);
  return manifest.attachments.filter((item) => ids.has(item.id)).map(attachmentDetails);
}

export async function getSessionAttachment(
  dataDir: string,
  sessionId: string,
  attachmentId: string,
): Promise<{ record: SessionAttachmentRecord; path: string; size: number } | null> {
  const manifest = readManifest(dataDir, sessionId);
  const record = manifest.attachments.find((item) => item.id === attachmentId);
  if (!record) return null;

  const relativeName = record.storageKey.split("/").pop();
  if (!relativeName) return null;
  const filePath = join(sessionDir(dataDir, sessionId), relativeName);
  try {
    const info = await stat(filePath);
    if (!info.isFile()) return null;
    return { record, path: filePath, size: info.size };
  } catch {
    return null;
  }
}

export function streamSessionAttachment(
  attachment: { record: SessionAttachmentRecord; path: string; size: number },
  res: ServerResponse,
): void {
  res.writeHead(200, {
    "Content-Type": attachment.record.mimeType,
    "Content-Length": attachment.size.toString(),
    "Cache-Control": "private, max-age=3600",
  });
  createReadStream(attachment.path).pipe(res as NodeJS.WritableStream);
}

export function deleteSessionAttachments(dataDir: string, sessionId: string): void {
  rmSync(sessionDir(dataDir, sessionId), { recursive: true, force: true });
}
