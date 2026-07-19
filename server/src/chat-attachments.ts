import { createHash, randomUUID } from "node:crypto";
import { copyFile, mkdir, readFile, realpath, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, extname, join, relative, resolve } from "node:path";

import { isPathWithinRoot } from "./git-utils.js";
import type { ChatAttachmentRef } from "./types.js";
import {
  resolveUploadAttachment,
  type UploadStoreConfigResolved,
} from "./uploads/local-upload-store.js";

export interface MaterializedChatAttachment {
  id: string;
  name: string;
  mimeType: string;
  sizeBytes: number;
  sha256?: string;
  relativePath: string;
}

export interface MaterializeChatAttachmentsResult {
  message: string;
  materialized: MaterializedChatAttachment[];
  imageInputs: Array<{ type: "image"; data: string; mimeType: string }>;
}

export interface MaterializeChatAttachmentsOptions {
  workspaceRoot: string;
  workspaceId?: string;
  sessionId: string;
  turnId?: string;
  message: string;
  attachments?: ChatAttachmentRef[];
  maxTurnBytes?: number;
  uploadStore?: UploadStoreConfigResolved;
}

export function trustedSessionAttachmentSourceRoots(): string[] {
  return [join(homedir(), "Library/Application Support/Yuwp/Audio/pi-voice")];
}

function normalizeFileName(name: string): string {
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

function dedupeFileName(name: string, used: Set<string>): string {
  if (!used.has(name)) {
    used.add(name);
    return name;
  }

  const ext = extname(name);
  const stem = ext.length > 0 ? name.slice(0, -ext.length) : name;
  let index = 2;
  while (true) {
    const candidate = `${stem}-${index}${ext}`;
    if (!used.has(candidate)) {
      used.add(candidate);
      return candidate;
    }
    index += 1;
  }
}

async function sha256ForFile(path: string): Promise<string> {
  const bytes = await readFile(path);
  return createHash("sha256").update(bytes).digest("hex");
}

export async function materializeChatAttachments(
  options: MaterializeChatAttachmentsOptions,
): Promise<MaterializeChatAttachmentsResult> {
  const refs = options.attachments ?? [];
  if (refs.length === 0) {
    return { message: options.message, materialized: [], imageInputs: [] };
  }

  const workspaceRootReal = await realpath(options.workspaceRoot);
  const turnId = options.turnId?.trim() || randomUUID();
  const targetDir = join(workspaceRootReal, ".pi", "attachments", options.sessionId, turnId);
  await mkdir(targetDir, { recursive: true });

  const usedNames = new Set<string>();
  const materialized: MaterializedChatAttachment[] = [];
  let totalBytes = 0;

  for (const ref of refs) {
    if (ref.type !== "attachment") {
      throw new Error(`Unsupported attachment payload for ${ref.id}`);
    }

    if (ref.source === "workspace") {
      if (!options.workspaceId) {
        throw new Error(`Workspace attachments require a workspace session: ${ref.id}`);
      }
      const workspacePath = ref.workspacePath?.trim();
      if (!workspacePath) {
        throw new Error(`workspacePath required for workspace attachment ${ref.id}`);
      }

      const resolved = resolve(workspaceRootReal, workspacePath);
      const resolvedReal = await realpath(resolved);
      if (!isPathWithinRoot(resolvedReal, workspaceRootReal)) {
        throw new Error(`Attachment path outside workspace root: ${workspacePath}`);
      }

      const info = await stat(resolvedReal);
      if (!info.isFile()) {
        throw new Error(`Attachment is not a file: ${workspacePath}`);
      }

      totalBytes += info.size;
      if (options.maxTurnBytes && totalBytes > options.maxTurnBytes) {
        throw new Error("Attachment payload exceeds max turn size");
      }

      const safeName = dedupeFileName(
        normalizeFileName(ref.name || basename(workspacePath) || "attachment"),
        usedNames,
      );
      const destination = join(targetDir, safeName);
      await copyFile(resolvedReal, destination);

      const relPath = relative(workspaceRootReal, destination).replaceAll("\\", "/");
      const sha256 = ref.sha256 || (await sha256ForFile(destination));

      materialized.push({
        id: ref.id,
        name: safeName,
        mimeType: ref.mimeType,
        sizeBytes: info.size,
        sha256,
        relativePath: relPath,
      });
      continue;
    }

    if (ref.source === "upload") {
      if (!options.uploadStore) {
        throw new Error("Upload attachments are not configured");
      }
      const record = await resolveUploadAttachment({
        config: options.uploadStore,
        workspaceId: options.workspaceId,
        sessionId: options.sessionId,
        ref,
      });
      const sizeBytes = record.sizeBytes ?? record.declaredSizeBytes;
      totalBytes += sizeBytes;
      if (options.maxTurnBytes && totalBytes > options.maxTurnBytes) {
        throw new Error("Attachment payload exceeds max turn size");
      }
      const safeName = dedupeFileName(normalizeFileName(record.safeName), usedNames);
      const destination = join(targetDir, safeName);
      if (!record.blobPath) {
        throw new Error(`Upload blob missing for ${ref.id}`);
      }
      await copyFile(record.blobPath, destination);
      const relPath = relative(workspaceRootReal, destination).replaceAll("\\", "/");
      materialized.push({
        id: ref.id,
        name: safeName,
        mimeType: record.mimeType,
        sizeBytes,
        sha256: record.sha256,
        relativePath: relPath,
      });
      continue;
    }

    throw new Error(`Unsupported attachment source for ${ref.id}: ${ref.source}`);
  }

  const imageAttachments = materialized.filter((item) => item.mimeType.startsWith("image/"));
  const imageInputs = await Promise.all(
    imageAttachments.map(async (item) => {
      const absolutePath = join(workspaceRootReal, item.relativePath);
      const bytes = await readFile(absolutePath);
      return {
        type: "image" as const,
        data: bytes.toString("base64"),
        mimeType: item.mimeType || "image/jpeg",
      };
    }),
  );

  const fileLines = materialized.map((item) => `- ${item.name}: ${item.relativePath}`);

  const sections: string[] = [];
  if (fileLines.length > 0) {
    sections.push(["Attached files:", ...fileLines].join("\n"));
  }

  const attachmentBlock = sections.join("\n\n");
  const message = attachmentBlock
    ? options.message.trim().length > 0
      ? `${options.message}\n\n${attachmentBlock}`
      : attachmentBlock
    : options.message;

  return {
    message,
    materialized,
    imageInputs,
  };
}
