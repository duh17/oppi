import { createHash } from "node:crypto";
import {
  createReadStream,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { stat } from "node:fs/promises";
import { basename, extname, join } from "node:path";
import type { ServerResponse } from "node:http";

import { generateId } from "./id.js";

const MANIFEST_VERSION = 1;
const MAX_SESSION_ATTACHMENT_BYTES = 50 * 1024 * 1024;
const DEFAULT_AUDIO_MIME_TYPE = "audio/wav";

export interface SessionAttachmentRecord {
  id: string;
  kind: "audio";
  mimeType: string;
  fileName: string;
  sizeBytes: number;
  storageKey: string;
  createdAt: number;
  toolCallId?: string;
  durationSeconds?: number;
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
    default:
      return "bin";
  }
}

function normalizeAudioMimeType(value: unknown): string {
  const mimeType = typeof value === "string" ? value.trim().toLowerCase() : "";
  return mimeType.startsWith("audio/") ? mimeType : DEFAULT_AUDIO_MIME_TYPE;
}

function safeFileName(value: unknown, mimeType: string): string {
  const raw = typeof value === "string" && value.trim() ? basename(value.trim()) : "tool-audio";
  const ext = extname(raw) ? "" : `.${mimeExtension(mimeType)}`;
  return `${raw}${ext}`;
}

function bytesFromAudioDetails(audio: Record<string, unknown>): Buffer | null {
  const path = typeof audio.path === "string" ? audio.path : undefined;
  if (path) {
    try {
      const info = statSync(path);
      if (!info.isFile() || info.size <= 0 || info.size > MAX_SESSION_ATTACHMENT_BYTES) return null;
      return readFileSync(path);
    } catch {
      return null;
    }
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

function sanitizeAudioDetails(
  root: Record<string, unknown>,
  audio: Record<string, unknown>,
): Record<string, unknown> {
  const sanitizedAudio = { ...audio } as Record<string, unknown>;
  delete sanitizedAudio.base64;
  delete sanitizedAudio.path;
  return { ...root, audio: sanitizedAudio };
}

export function materializeToolAudioDetails({
  dataDir,
  sessionId,
  toolCallId,
  details,
}: MaterializeToolAudioOptions): unknown {
  const root = asRecord(details);
  const audio = asRecord(root?.audio);
  if (!root || !audio || audio.kind !== "audio") return details;

  if (typeof audio.id === "string" && audio.id.trim()) {
    return sanitizeAudioDetails(root, audio);
  }

  const bytes = bytesFromAudioDetails(audio);
  if (!bytes) {
    return sanitizeAudioDetails(root, audio);
  }

  const mimeType = normalizeAudioMimeType(audio.mimeType);
  const fileName = safeFileName(audio.fileName ?? audio.path, mimeType);
  const id = attachmentIdFor(toolCallId, bytes);
  const storageKey = `${sessionId}/${id}.${mimeExtension(mimeType, fileName)}`;
  const dir = sessionDir(dataDir, sessionId);
  const filePath = join(dir, `${id}.${mimeExtension(mimeType, fileName)}`);

  mkdirSync(dir, { recursive: true, mode: 0o700 });
  if (!existsSync(filePath)) {
    writeFileSync(filePath, bytes, { mode: 0o600 });
  }

  const record: SessionAttachmentRecord = {
    id,
    kind: "audio",
    mimeType,
    fileName,
    sizeBytes: bytes.length,
    storageKey,
    createdAt: Date.now(),
    ...(toolCallId ? { toolCallId } : {}),
    ...(typeof audio.durationSeconds === "number"
      ? { durationSeconds: audio.durationSeconds }
      : {}),
    ...(typeof root.message === "string" ? { text: root.message } : {}),
  };

  const manifest = readManifest(dataDir, sessionId);
  const existingIndex = manifest.attachments.findIndex((item) => item.id === id);
  if (existingIndex >= 0) {
    manifest.attachments[existingIndex] = { ...manifest.attachments[existingIndex], ...record };
  } else {
    manifest.attachments.push(record);
  }
  writeManifest(dataDir, sessionId, manifest);

  return {
    ...root,
    audio: {
      kind: record.kind,
      id: record.id,
      mimeType: record.mimeType,
      fileName: record.fileName,
      sizeBytes: record.sizeBytes,
      storageKey: record.storageKey,
      ...(record.durationSeconds !== undefined ? { durationSeconds: record.durationSeconds } : {}),
    },
  };
}

export function sessionAttachmentDetailsForToolCall(
  dataDir: string,
  sessionId: string,
  toolCallId: string | undefined,
  details: unknown,
): unknown {
  if (!toolCallId) return details;
  const root = asRecord(details);
  const audio = asRecord(root?.audio);
  if (!root || !audio || audio.kind !== "audio") return details;
  if (typeof audio.id === "string" && audio.id.trim()) {
    return sanitizeAudioDetails(root, audio);
  }

  const manifest = readManifest(dataDir, sessionId);
  const record = manifest.attachments.find((item) => item.toolCallId === toolCallId);
  if (!record) {
    return sanitizeAudioDetails(root, audio);
  }

  return {
    ...root,
    audio: {
      kind: record.kind,
      id: record.id,
      mimeType: record.mimeType,
      fileName: record.fileName,
      sizeBytes: record.sizeBytes,
      storageKey: record.storageKey,
      ...(record.durationSeconds !== undefined ? { durationSeconds: record.durationSeconds } : {}),
    },
  };
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
