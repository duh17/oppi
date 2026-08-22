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
import type { IncomingMessage, ServerResponse } from "node:http";

import { logRejectedByteRange, parseByteRangeHeader } from "./http-range.js";
import { generateId } from "./id.js";

const MANIFEST_VERSION = 1;
const MAX_SESSION_ATTACHMENT_BYTES = 50 * 1024 * 1024;
const DEFAULT_AUDIO_MIME_TYPE = "audio/wav";
const DEFAULT_IMAGE_MIME_TYPE = "image/png";
const DEFAULT_VIDEO_MIME_TYPE = "video/mp4";

export type SessionAttachmentKind = "audio" | "image" | "video";

export interface SessionAttachmentRecord {
  id: string;
  kind: SessionAttachmentKind;
  mimeType: string;
  fileName: string;
  sizeBytes: number;
  storageKey: string;
  createdAt: number;
  sha256?: string;
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
   * Explicit roots from which server-side media paths may be copied.
   * When omitted, media path fields are treated as untrusted metadata and ignored.
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

export interface AddSessionAttachmentFileOptions {
  dataDir: string;
  sessionId: string;
  toolCallId?: string;
  path: string;
  kind?: SessionAttachmentKind;
  mimeType?: string;
  fileName?: string;
  durationSeconds?: number;
  width?: number;
  height?: number;
  text?: string;
  deleteSource?: boolean;
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
    case "image/tif":
      return fallbackExt === "tif" ? "tif" : "tiff";
    case "image/x-icon":
    case "image/vnd.microsoft.icon":
    case "image/icon":
      return "ico";
    case "video/mp4":
    case "application/mp4":
      return "mp4";
    case "video/quicktime":
      return "mov";
    case "video/webm":
      return "webm";
    case "video/x-matroska":
      return "mkv";
    default:
      return "bin";
  }
}

function defaultFileStem(kind: SessionAttachmentKind): string {
  switch (kind) {
    case "image":
      return "tool-image";
    case "video":
      return "tool-video";
    case "audio":
      return "tool-audio";
  }
}

function normalizeAudioMimeType(value: unknown): string {
  const mimeType = typeof value === "string" ? value.trim().toLowerCase() : "";
  return mimeType.startsWith("audio/") ? mimeType : DEFAULT_AUDIO_MIME_TYPE;
}

function normalizeImageMimeType(value: unknown): string {
  const mimeType = typeof value === "string" ? value.trim().toLowerCase() : "";
  return mimeType.startsWith("image/") ? mimeType : DEFAULT_IMAGE_MIME_TYPE;
}

function normalizeVideoMimeType(value: unknown): string {
  const mimeType = typeof value === "string" ? value.trim().toLowerCase() : "";
  return mimeType.startsWith("video/") || mimeType === "application/mp4"
    ? mimeType
    : DEFAULT_VIDEO_MIME_TYPE;
}

function normalizeMimeTypeForKind(kind: SessionAttachmentKind, value: unknown): string {
  switch (kind) {
    case "audio":
      return normalizeAudioMimeType(value);
    case "image":
      return normalizeImageMimeType(value);
    case "video":
      return normalizeVideoMimeType(value);
  }
}

function sessionAttachmentKindFromValue(value: unknown): SessionAttachmentKind | undefined {
  return value === "audio" || value === "image" || value === "video" ? value : undefined;
}

function sessionAttachmentKindFromMimeType(value: unknown): SessionAttachmentKind | undefined {
  const mimeType = typeof value === "string" ? value.trim().toLowerCase() : "";
  if (mimeType.startsWith("audio/")) return "audio";
  if (mimeType.startsWith("image/")) return "image";
  if (mimeType.startsWith("video/") || mimeType === "application/mp4") return "video";
  return undefined;
}

function readUInt24LE(bytes: Buffer, offset: number): number {
  return bytes[offset] + (bytes[offset + 1] << 8) + (bytes[offset + 2] << 16);
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

function attachmentSha256(bytes: Buffer): string {
  return createHash("sha256").update(bytes).digest("hex");
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

function sanitizedMediaRecord(media: Record<string, unknown>): Record<string, unknown> {
  const sanitized = { ...media } as Record<string, unknown>;
  delete sanitized.base64;
  delete sanitized.data;
  delete sanitized.path;
  return sanitized;
}

function sanitizeMediaDetails(
  root: Record<string, unknown>,
  key: "audio" | "image",
  media: Record<string, unknown>,
): Record<string, unknown> {
  return { ...root, [key]: sanitizedMediaRecord(media) };
}

function validDimensions(
  width: number,
  height: number,
): { width: number; height: number } | undefined {
  return Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0
    ? { width: Math.round(width), height: Math.round(height) }
    : undefined;
}

function svgLength(raw: string | undefined): number | undefined {
  if (!raw) return undefined;
  const value = raw.trim();
  if (!value || value.endsWith("%")) return undefined;
  const match = value.match(/^([+-]?(?:\d+(?:\.\d+)?|\.\d+))(?:px)?$/i);
  if (!match) return undefined;
  const number = Number(match[1]);
  return Number.isFinite(number) && number > 0 ? number : undefined;
}

function svgAttribute(openingTag: string, name: string): string | undefined {
  const match = openingTag.match(new RegExp(`(?:^|\\s)${name}\\s*=\\s*(["'])(.*?)\\1`, "i"));
  return match?.[2];
}

function svgDimensions(bytes: Buffer): { width: number; height: number } | undefined {
  const text = bytes.subarray(0, Math.min(bytes.length, 8192)).toString("utf8");
  const openingTag = text.match(/<svg\b[^>]*>/i)?.[0];
  if (!openingTag) return undefined;

  const viewBox = openingTag.match(
    /viewBox\s*=\s*["']?\s*[-+]?\d*\.?\d+(?:,|\s)+[-+]?\d*\.?\d+(?:,|\s)+([-+]?\d*\.?\d+)(?:,|\s)+([-+]?\d*\.?\d+)/i,
  );
  if (viewBox) {
    const width = Number(viewBox[1]);
    const height = Number(viewBox[2]);
    const dimensions = validDimensions(width, height);
    if (dimensions) return dimensions;
  }

  return validDimensions(
    svgLength(svgAttribute(openingTag, "width")) ?? 0,
    svgLength(svgAttribute(openingTag, "height")) ?? 0,
  );
}

function webpDimensions(bytes: Buffer): { width: number; height: number } | undefined {
  if (
    bytes.length < 30 ||
    bytes.subarray(0, 4).toString("ascii") !== "RIFF" ||
    bytes.subarray(8, 12).toString("ascii") !== "WEBP"
  ) {
    return undefined;
  }

  let offset = 12;
  while (offset + 8 <= bytes.length) {
    const chunkType = bytes.subarray(offset, offset + 4).toString("ascii");
    const chunkSize = bytes.readUInt32LE(offset + 4);
    const payload = offset + 8;
    if (payload + chunkSize > bytes.length) return undefined;

    if (chunkType === "VP8X" && chunkSize >= 10) {
      return validDimensions(
        readUInt24LE(bytes, payload + 4) + 1,
        readUInt24LE(bytes, payload + 7) + 1,
      );
    }
    if (chunkType === "VP8L" && chunkSize >= 5 && bytes[payload] === 0x2f) {
      const b0 = bytes[payload + 1];
      const b1 = bytes[payload + 2];
      const b2 = bytes[payload + 3];
      const b3 = bytes[payload + 4];
      const width = 1 + (((b1 & 0x3f) << 8) | b0);
      const height = 1 + (((b3 & 0x0f) << 10) | (b2 << 2) | ((b1 & 0xc0) >> 6));
      return validDimensions(width, height);
    }
    if (
      chunkType === "VP8 " &&
      chunkSize >= 10 &&
      bytes[payload + 3] === 0x9d &&
      bytes[payload + 4] === 0x01 &&
      bytes[payload + 5] === 0x2a
    ) {
      return validDimensions(
        bytes.readUInt16LE(payload + 6) & 0x3fff,
        bytes.readUInt16LE(payload + 8) & 0x3fff,
      );
    }

    offset = payload + chunkSize + (chunkSize % 2);
  }

  return undefined;
}

function bmpDimensions(bytes: Buffer): { width: number; height: number } | undefined {
  if (bytes.length < 26 || bytes.subarray(0, 2).toString("ascii") !== "BM") return undefined;
  const dibSize = bytes.readUInt32LE(14);
  if (dibSize === 12 && bytes.length >= 24) {
    return validDimensions(bytes.readUInt16LE(18), bytes.readUInt16LE(20));
  }
  if (dibSize >= 40 && bytes.length >= 26) {
    return validDimensions(bytes.readInt32LE(18), Math.abs(bytes.readInt32LE(22)));
  }
  return undefined;
}

function tiffDimensions(bytes: Buffer): { width: number; height: number } | undefined {
  if (bytes.length < 8) return undefined;
  const marker = bytes.subarray(0, 2).toString("ascii");
  const littleEndian = marker === "II";
  if (!littleEndian && marker !== "MM") return undefined;

  const read16 = (offset: number): number =>
    littleEndian ? bytes.readUInt16LE(offset) : bytes.readUInt16BE(offset);
  const read32 = (offset: number): number =>
    littleEndian ? bytes.readUInt32LE(offset) : bytes.readUInt32BE(offset);
  if (read16(2) !== 42) return undefined;
  const ifdOffset = read32(4);
  if (ifdOffset < 8 || ifdOffset + 2 > bytes.length) return undefined;

  const entryCount = read16(ifdOffset);
  let width: number | undefined;
  let height: number | undefined;
  for (let index = 0; index < entryCount; index += 1) {
    const entryOffset = ifdOffset + 2 + index * 12;
    if (entryOffset + 12 > bytes.length) break;
    const tag = read16(entryOffset);
    if (tag !== 256 && tag !== 257) continue;
    const type = read16(entryOffset + 2);
    const value =
      type === 3 ? read16(entryOffset + 8) : type === 4 ? read32(entryOffset + 8) : undefined;
    if (tag === 256) width = value;
    if (tag === 257) height = value;
  }
  return validDimensions(width ?? 0, height ?? 0);
}

function icoDimensions(bytes: Buffer): { width: number; height: number } | undefined {
  if (
    bytes.length < 8 ||
    bytes.readUInt16LE(0) !== 0 ||
    ![1, 2].includes(bytes.readUInt16LE(2)) ||
    bytes.readUInt16LE(4) < 1
  ) {
    return undefined;
  }
  const width = bytes[6] === 0 ? 256 : bytes[6];
  const height = bytes[7] === 0 ? 256 : bytes[7];
  return validDimensions(width, height);
}

function imageDimensions(
  bytes: Buffer,
  mimeType: string,
): { width: number; height: number } | undefined {
  if (
    bytes.length >= 24 &&
    bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
  ) {
    return validDimensions(bytes.readUInt32BE(16), bytes.readUInt32BE(20));
  }

  if (bytes.length >= 10 && bytes.subarray(0, 3).toString("ascii") === "GIF") {
    return validDimensions(bytes.readUInt16LE(6), bytes.readUInt16LE(8));
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
        return validDimensions(bytes.readUInt16BE(offset + 7), bytes.readUInt16BE(offset + 5));
      }
      offset += 2 + length;
    }
  }

  return (
    webpDimensions(bytes) ??
    bmpDimensions(bytes) ??
    tiffDimensions(bytes) ??
    icoDimensions(bytes) ??
    (mimeType === "image/svg+xml" ? svgDimensions(bytes) : undefined)
  );
}

function attachmentDetails(record: SessionAttachmentRecord): Record<string, unknown> {
  return {
    kind: record.kind,
    id: record.id,
    mimeType: record.mimeType,
    fileName: record.fileName,
    sizeBytes: record.sizeBytes,
    storageKey: record.storageKey,
    ...(record.sha256 !== undefined ? { sha256: record.sha256 } : {}),
    ...(record.durationSeconds !== undefined ? { durationSeconds: record.durationSeconds } : {}),
    ...(record.width !== undefined ? { width: record.width } : {}),
    ...(record.height !== undefined ? { height: record.height } : {}),
  };
}

function imageAttachmentDetails(record: SessionAttachmentRecord): Record<string, unknown> {
  return attachmentDetails(record);
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
  width?: number;
  height?: number;
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

  const detectedDimensions = kind === "image" ? imageDimensions(bytes, mimeType) : undefined;
  const providedDimensions = validDimensions(options.width ?? 0, options.height ?? 0);
  const dimensions = providedDimensions ?? detectedDimensions;
  const record: SessionAttachmentRecord = {
    id,
    kind,
    mimeType,
    fileName,
    sizeBytes: bytes.length,
    storageKey,
    createdAt: Date.now(),
    sha256: attachmentSha256(bytes),
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

export function addSessionAttachmentFile(
  options: AddSessionAttachmentFileOptions,
): Record<string, unknown> {
  const realPath = realpathSync(options.path);
  const info = statSync(realPath);
  if (!info.isFile()) {
    throw new Error("Attachment source must be a file");
  }
  if (info.size <= 0) {
    throw new Error("Attachment source is empty");
  }
  if (info.size > MAX_SESSION_ATTACHMENT_BYTES) {
    throw new Error(`Attachment source exceeds ${MAX_SESSION_ATTACHMENT_BYTES} bytes`);
  }

  const kind = options.kind ?? sessionAttachmentKindFromMimeType(options.mimeType);
  if (!kind) {
    throw new Error("Attachment kind or media MIME type is required");
  }
  const mimeType = normalizeMimeTypeForKind(kind, options.mimeType);
  const bytes = readFileSync(realPath);
  const record = storeAttachment({
    dataDir: options.dataDir,
    sessionId: options.sessionId,
    toolCallId: options.toolCallId,
    kind,
    mimeType,
    fileName: safeFileName(options.fileName ?? options.path, mimeType, kind),
    bytes,
    ...(options.durationSeconds !== undefined ? { durationSeconds: options.durationSeconds } : {}),
    ...(options.width !== undefined ? { width: options.width } : {}),
    ...(options.height !== undefined ? { height: options.height } : {}),
    ...(options.text !== undefined ? { text: options.text } : {}),
  });

  if (options.deleteSource === true) {
    rmSync(options.path, { force: true });
  }

  return attachmentDetails(record);
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
      nextRoot = sanitizeMediaDetails(nextRoot, "image", image);
    } else {
      const bytes = bytesFromImageLike(image);
      if (!bytes) {
        nextRoot = sanitizeMediaDetails(nextRoot, "image", image);
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
        nextRoot = { ...nextRoot, image: imageAttachmentDetails(record) };
      }
    }
  }

  const mediaArray = Array.isArray(root.media) ? root.media : undefined;
  if (mediaArray) {
    let changed = false;
    const nextMedia = mediaArray.map((entry) => {
      const media = asRecord(entry);
      const kind = media ? sessionAttachmentKindFromValue(media.kind) : undefined;
      if (!media || !kind) return entry;

      changed = true;
      if (typeof media.id === "string" && media.id.trim()) {
        return sanitizedMediaRecord(media);
      }

      const bytes = bytesFromMediaDetails(kind, media, trustedSourceRoots);
      if (!bytes) {
        return sanitizedMediaRecord(media);
      }

      const mimeType = normalizeMimeTypeForKind(kind, media.mimeType);
      const record = storeAttachment({
        dataDir,
        sessionId,
        toolCallId,
        kind,
        mimeType,
        fileName: safeFileName(media.fileName ?? media.path, mimeType, kind),
        bytes,
        ...(typeof media.durationSeconds === "number"
          ? { durationSeconds: media.durationSeconds }
          : {}),
        ...(typeof media.width === "number" ? { width: media.width } : {}),
        ...(typeof media.height === "number" ? { height: media.height } : {}),
        ...(typeof root.message === "string" ? { text: root.message } : {}),
      });
      return attachmentDetails(record);
    });
    if (changed) {
      nextRoot = { ...nextRoot, media: nextMedia };
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

function bytesFromVideoLike(
  video: Record<string, unknown>,
  trustedSourceRoots: string[] | undefined,
): Buffer | null {
  const path = typeof video.path === "string" ? video.path : undefined;
  if (path) {
    const bytes = bytesFromTrustedPath(path, trustedSourceRoots);
    if (bytes) return bytes;
  }

  const base64 = base64FromMediaRecord(video) ?? "";
  if (!base64) return null;
  const bytes = Buffer.from(base64, "base64");
  if (bytes.length <= 0 || bytes.length > MAX_SESSION_ATTACHMENT_BYTES) return null;
  return bytes;
}

function bytesFromMediaDetails(
  kind: SessionAttachmentKind,
  media: Record<string, unknown>,
  trustedSourceRoots: string[] | undefined,
): Buffer | null {
  switch (kind) {
    case "audio":
      return bytesFromAudioDetails(media, trustedSourceRoots);
    case "image":
      return bytesFromImageLike(media);
    case "video":
      return bytesFromVideoLike(media, trustedSourceRoots);
  }
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

  const kind = sessionAttachmentKindFromValue(media.kind);
  if (!kind) {
    return undefined;
  }

  const bytes = bytesFromMediaDetails(kind, media, undefined);
  return bytes ? attachmentIdFor(toolCallId, bytes) : undefined;
}

function findAttachmentRecordForMedia(
  manifest: SessionAttachmentManifest,
  toolCallId: string,
  kind: SessionAttachmentKind,
  media: Record<string, unknown>,
  options: { allowToolCallKindFallback?: boolean } = {},
): SessionAttachmentRecord | undefined {
  const explicitId = attachmentIdFromMediaRecord(toolCallId, media);
  if (explicitId) {
    const byId = manifest.attachments.find((item) => item.id === explicitId && item.kind === kind);
    if (byId) {
      return byId;
    }
  }

  if (options.allowToolCallKindFallback === false) {
    return undefined;
  }

  return manifest.attachments.find((item) => item.toolCallId === toolCallId && item.kind === kind);
}

function mediaDetailsForReplayRecord(
  record: SessionAttachmentRecord,
  kind: SessionAttachmentKind,
  _media: Record<string, unknown>,
): Record<string, unknown> {
  return kind === "image" ? imageAttachmentDetails(record) : attachmentDetails(record);
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
    if (type !== "image" && type !== "audio" && type !== "output_audio" && type !== "video") {
      continue;
    }
    const id = attachmentIdFromMediaRecord(toolCallId, {
      ...record,
      kind: type === "image" ? "image" : type === "video" ? "video" : "audio",
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
    if (!media || !sessionAttachmentKindFromValue(media.kind)) continue;
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
      : sanitizeMediaDetails(nextRoot, key, media);
  }

  const mediaArray = Array.isArray(root.media) ? root.media : undefined;
  if (mediaArray) {
    let changed = false;
    const nextMedia = mediaArray.map((entry) => {
      const media = asRecord(entry);
      const kind = media ? sessionAttachmentKindFromValue(media.kind) : undefined;
      if (!media || !kind) return entry;

      changed = true;
      const record = findAttachmentRecordForMedia(manifest, toolCallId, kind, media, {
        allowToolCallKindFallback: false,
      });
      return record
        ? mediaDetailsForReplayRecord(record, kind, media)
        : sanitizedMediaRecord(media);
    });
    if (changed) {
      nextRoot = { ...nextRoot, media: nextMedia };
    }
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
  req: IncomingMessage,
  res: ServerResponse,
  method = "GET",
): void {
  const commonHeaders = {
    "Content-Type": attachment.record.mimeType,
    "Cache-Control": "private, max-age=3600",
    "Accept-Ranges": "bytes",
  };
  const range = parseByteRangeHeader(req.headers?.range, attachment.size);
  const isHeadRequest = method.toUpperCase() === "HEAD";

  if (range.kind === "invalid" || range.kind === "unsatisfiable") {
    logRejectedByteRange("session-attachment", req.headers?.range, range.kind, attachment.size);
    res.writeHead(416, {
      ...commonHeaders,
      "Content-Range": `bytes */${attachment.size}`,
      "Content-Length": "0",
    });
    res.end();
    return;
  }

  if (range.kind === "valid") {
    const contentLength = range.end - range.start + 1;
    res.writeHead(206, {
      ...commonHeaders,
      "Content-Range": `bytes ${range.start}-${range.end}/${attachment.size}`,
      "Content-Length": contentLength.toString(),
    });
    if (isHeadRequest) {
      res.end();
      return;
    }
    pipeAttachmentStream(attachment.path, res, range);
    return;
  }

  res.writeHead(200, {
    ...commonHeaders,
    "Content-Length": attachment.size.toString(),
  });
  if (isHeadRequest) {
    res.end();
    return;
  }
  pipeAttachmentStream(attachment.path, res);
}

function pipeAttachmentStream(
  filePath: string,
  res: ServerResponse,
  range?: { start: number; end: number },
): void {
  const stream = range
    ? createReadStream(filePath, { start: range.start, end: range.end })
    : createReadStream(filePath);

  stream.on("error", (error) => {
    if (!res.headersSent) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Failed to read attachment" }));
      return;
    }
    res.destroy(error);
  });
  stream.pipe(res as NodeJS.WritableStream);
}

export function deleteSessionAttachments(dataDir: string, sessionId: string): boolean {
  const dir = sessionDir(dataDir, sessionId);
  const existed = existsSync(dir);
  rmSync(dir, { recursive: true, force: true });
  return existed;
}
