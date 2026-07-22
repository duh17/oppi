import { randomUUID } from "node:crypto";

import type { PiMessage } from "./pi-events.js";
import type {
  ChatAttachmentRef,
  MessageQueueDraftItem,
  MessageQueueItem,
  MessageQueueKind,
  MessageQueueState,
  ServerMessage,
} from "./types.js";

export interface QueueImageContent {
  type: "image";
  data: string;
  mimeType: string;
}

export interface MutableMessageQueueState<T extends MessageQueueItem = MessageQueueItem> {
  version: number;
  steering: T[];
  followUp: T[];
}

export interface StartedQueueItem<T extends MessageQueueItem = MessageQueueItem> {
  kind: MessageQueueKind;
  item: T;
  queueVersion: number;
}

export type QueueStateMessage = Extract<ServerMessage, { type: "queue_state" }>;
export type QueueItemStartedMessage = Extract<ServerMessage, { type: "queue_item_started" }>;

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
  const attachments = cloneAttachmentRefs(item.attachments);
  return {
    id: item.id,
    message: item.message,
    createdAt: item.createdAt,
    ...(attachments ? { attachments } : {}),
  };
}

export function cloneQueueState(queue: MutableMessageQueueState): MessageQueueState {
  return {
    version: queue.version,
    steering: queue.steering.map(cloneQueueItem),
    followUp: queue.followUp.map(cloneQueueItem),
  };
}

export function queueStateMessage(queue: MutableMessageQueueState): QueueStateMessage {
  return {
    type: "queue_state",
    queue: cloneQueueState(queue),
  };
}

export function queueItemStartedMessage(
  started: StartedQueueItem<MessageQueueItem>,
): QueueItemStartedMessage {
  return {
    type: "queue_item_started",
    kind: started.kind,
    item: cloneQueueItem(started.item),
    queueVersion: started.queueVersion,
  };
}

/** Queue versions are protocol counters: never negative, fractional, or lossy. */
export function isQueueVersion(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

export const QUEUE_VERSION_INVALID_ERROR = "Queue version must be a nonnegative safe integer";
export const QUEUE_VERSION_EXHAUSTED_ERROR = `Queue version exhausted at ${Number.MAX_SAFE_INTEGER}; start a new session to reset the queue counter`;

export function assertQueueVersion(value: unknown): asserts value is number {
  if (!isQueueVersion(value)) {
    throw new Error(QUEUE_VERSION_INVALID_ERROR);
  }
}

/**
 * Queue versions never wrap: wrapping would let a pre-rollover stale CAS match
 * again. Exhaustion is recoverable by starting a new session, whose queue starts
 * at version zero. Callers must compute the next version before mutating state.
 */
export function nextQueueVersion(value: unknown): number {
  assertQueueVersion(value);
  if (value === Number.MAX_SAFE_INTEGER) {
    throw new Error(QUEUE_VERSION_EXHAUSTED_ERROR);
  }
  return value + 1;
}

export function parseQueueState(value: unknown): MessageQueueState | undefined {
  const record = asRecord(value);
  const queue = asRecord(record?.queue) ?? record;
  if (!queue) return undefined;
  const version = queue.version;
  const steering = parseQueueItems(queue.steering);
  const followUp = parseQueueItems(queue.followUp);
  if (!isQueueVersion(version) || !steering || !followUp) return undefined;
  return { version, steering, followUp };
}

export function requireQueueState(value: unknown, errorMessage: string): MessageQueueState {
  const queue = parseQueueState(value);
  if (!queue) {
    throw new Error(errorMessage);
  }
  return queue;
}

export function assertQueueBaseVersion(
  queue: Pick<MutableMessageQueueState, "version">,
  baseVersion: number,
): void {
  assertQueueVersion(queue.version);
  assertQueueVersion(baseVersion);
  if (baseVersion !== queue.version) {
    throw new Error(`Queue version mismatch: expected ${queue.version}, got ${baseVersion}`);
  }
}

function parseQueueItems(value: unknown): MessageQueueItem[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const items: MessageQueueItem[] = [];
  for (const raw of value) {
    const record = asRecord(raw);
    if (!record) return undefined;
    const message = typeof record.message === "string" ? record.message : undefined;
    if (message === undefined) return undefined;
    items.push(
      cloneQueueItem({
        id: normalizeQueueId(typeof record.id === "string" ? record.id : undefined),
        message,
        createdAt:
          typeof record.createdAt === "number" && Number.isFinite(record.createdAt)
            ? Math.trunc(record.createdAt)
            : Date.now(),
        ...(Array.isArray(record.attachments)
          ? { attachments: record.attachments as ChatAttachmentRef[] }
          : {}),
      }),
    );
  }
  return items;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null
    ? (value as Record<string, unknown>)
    : undefined;
}

export function queueImagesFromPromptImages(
  images: QueueImageContent[] | undefined,
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

export function promptImagesFromQueue(
  images: QueueImageContent[] | undefined,
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

export function dequeueQueueItemByText<T extends MessageQueueItem>(
  queue: MutableMessageQueueState<T>,
  text: string | undefined,
  matches: (item: T, text: string) => boolean = (item, value) => item.message.trim() === value,
): StartedQueueItem<T> | null {
  const normalized = text?.trim();
  if (!normalized) return null;

  const dequeue = (kind: MessageQueueKind, list: T[]): StartedQueueItem<T> | null => {
    const index = list.findIndex((item) => matches(item, normalized));
    if (index === -1) return null;
    const nextVersion = nextQueueVersion(queue.version);
    const [item] = list.splice(index, 1);
    if (!item) return null;
    queue.version = nextVersion;
    return { kind, item, queueVersion: queue.version };
  };

  return dequeue("steer", queue.steering) ?? dequeue("follow_up", queue.followUp);
}

export function extractQueuedUserText(
  message: Pick<PiMessage, "content"> | { content?: unknown },
): string {
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
      attachments: cloneAttachmentRefs(item.attachments),
      createdAt:
        typeof item.createdAt === "number" && Number.isFinite(item.createdAt)
          ? Math.trunc(item.createdAt)
          : Date.now(),
    });
  }

  return normalized;
}
