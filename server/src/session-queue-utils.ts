import { randomUUID } from "node:crypto";

import type { PiMessage } from "./pi-events.js";
import type {
  ChatAttachmentRef,
  ImageAttachment,
  MessageQueueDraftItem,
  MessageQueueItem,
  MessageQueueState,
} from "./types.js";

export interface QueueImageContent {
  type: "image";
  data: string;
  mimeType: string;
}

interface SessionMessageQueueStoreLike {
  version: number;
  steering: MessageQueueItem[];
  followUp: MessageQueueItem[];
}

function cloneImageAttachment(image: ImageAttachment): ImageAttachment {
  return {
    data: image.data,
    mimeType: image.mimeType,
  };
}

function cloneImageAttachments(
  images: ImageAttachment[] | undefined,
): ImageAttachment[] | undefined {
  if (!images || images.length === 0) {
    return undefined;
  }

  return images.map(cloneImageAttachment);
}

function cloneAttachmentRef(attachment: ChatAttachmentRef): ChatAttachmentRef {
  return {
    type: "attachment",
    id: attachment.id,
    source: attachment.source,
    name: attachment.name,
    mimeType: attachment.mimeType,
    sizeBytes: attachment.sizeBytes,
    ...(attachment.sha256 ? { sha256: attachment.sha256 } : {}),
    ...(attachment.kind ? { kind: attachment.kind } : {}),
    ...(attachment.workspacePath ? { workspacePath: attachment.workspacePath } : {}),
  };
}

function cloneAttachmentRefs(
  attachments: ChatAttachmentRef[] | undefined,
): ChatAttachmentRef[] | undefined {
  if (!attachments || attachments.length === 0) {
    return undefined;
  }

  return attachments.map(cloneAttachmentRef);
}

export function cloneQueueItem(item: MessageQueueItem): MessageQueueItem {
  return {
    id: item.id,
    message: item.message,
    createdAt: item.createdAt,
    images: cloneImageAttachments(item.images),
    attachments: cloneAttachmentRefs(item.attachments),
  };
}

export function cloneQueueState(queue: SessionMessageQueueStoreLike): MessageQueueState {
  return {
    version: queue.version,
    steering: queue.steering.map(cloneQueueItem),
    followUp: queue.followUp.map(cloneQueueItem),
  };
}

export function queueImagesFromPromptImages(
  images: QueueImageContent[] | undefined,
): ImageAttachment[] | undefined {
  if (!images || images.length === 0) {
    return undefined;
  }

  return images.map((image) => ({
    data: image.data,
    mimeType: image.mimeType,
  }));
}

export function promptImagesFromQueue(
  images: ImageAttachment[] | undefined,
): QueueImageContent[] | undefined {
  if (!images || images.length === 0) {
    return undefined;
  }

  return images.map((image) => ({
    type: "image",
    data: image.data,
    mimeType: image.mimeType,
  }));
}

export function extractQueuedUserText(message: PiMessage): string {
  const content = message.content;

  if (typeof content === "string") {
    return content;
  }

  if (!Array.isArray(content)) {
    return "";
  }

  const textParts: string[] = [];
  for (const part of content as unknown[]) {
    if (!part || typeof part !== "object") {
      continue;
    }

    const block = part as { type?: unknown; text?: unknown };
    const type = block.type;
    if (
      (type === "text" || type === "input_text" || type === "output_text") &&
      typeof block.text === "string"
    ) {
      textParts.push(block.text);
    }
  }

  return textParts.join("");
}

export function normalizeQueueId(id: string | undefined): string {
  const trimmed = id?.trim();
  if (!trimmed) {
    return randomUUID();
  }

  return trimmed;
}

export function normalizeQueueMessage(message: string): string {
  if (typeof message !== "string") {
    throw new Error("Queue item message must be a string");
  }

  return message;
}

export function normalizeDraftItems(items: MessageQueueDraftItem[]): MessageQueueItem[] {
  const normalized: MessageQueueItem[] = [];

  for (const item of items) {
    normalized.push({
      id: normalizeQueueId(item.id),
      message: normalizeQueueMessage(item.message),
      images: cloneImageAttachments(item.images),
      attachments: cloneAttachmentRefs(item.attachments),
      createdAt:
        typeof item.createdAt === "number" && Number.isFinite(item.createdAt)
          ? Math.trunc(item.createdAt)
          : Date.now(),
    });
  }

  return normalized;
}
