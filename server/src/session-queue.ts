import { randomUUID } from "node:crypto";

import type { PiMessage } from "./pi-events.js";
import type { SdkBackend } from "./sdk-backend.js";
import type {
  ImageAttachment,
  MessageQueueDraftItem,
  MessageQueueItem,
  MessageQueueKind,
  MessageQueueState,
  ServerMessage,
} from "./types.js";

interface QueueImageContent {
  type: "image";
  data: string;
  mimeType: string;
}

export interface SessionMessageQueueStore {
  version: number;
  steering: MessageQueueItem[];
  followUp: MessageQueueItem[];
}

export interface SessionMessageQueueState {
  sdkBackend: SdkBackend;
  messageQueue?: SessionMessageQueueStore;
}

export interface SessionMessageQueueCoordinatorDeps {
  getActiveSession: (key: string) => SessionMessageQueueState | undefined;
  broadcast: (key: string, message: ServerMessage) => void;
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

function cloneQueueItem(item: MessageQueueItem): MessageQueueItem {
  return {
    id: item.id,
    message: item.message,
    createdAt: item.createdAt,
    images: cloneImageAttachments(item.images),
  };
}

function cloneQueueState(queue: SessionMessageQueueStore): MessageQueueState {
  return {
    version: queue.version,
    steering: queue.steering.map(cloneQueueItem),
    followUp: queue.followUp.map(cloneQueueItem),
  };
}

function queueImagesFromPromptImages(
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

function promptImagesFromQueue(
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

function extractQueuedUserText(message: PiMessage): string {
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

function normalizeQueueId(id: string | undefined): string {
  const trimmed = id?.trim();
  if (!trimmed) {
    return randomUUID();
  }

  return trimmed;
}

function normalizeQueueMessage(message: string): string {
  if (typeof message !== "string") {
    throw new Error("Queue item message must be a string");
  }

  return message;
}

function normalizeDraftItems(items: MessageQueueDraftItem[]): MessageQueueItem[] {
  const normalized: MessageQueueItem[] = [];

  for (const item of items) {
    normalized.push({
      id: normalizeQueueId(item.id),
      message: normalizeQueueMessage(item.message),
      images: cloneImageAttachments(item.images),
      createdAt:
        typeof item.createdAt === "number" && Number.isFinite(item.createdAt)
          ? Math.trunc(item.createdAt)
          : Date.now(),
    });
  }

  return normalized;
}

function reconcileItemsWithTextQueue(
  existing: MessageQueueItem[],
  queuedTexts: readonly string[],
): MessageQueueItem[] {
  const next: MessageQueueItem[] = [];
  const consumed = new Set<number>();

  for (const text of queuedTexts) {
    const matchIdx = existing.findIndex((item, idx) => !consumed.has(idx) && item.message === text);

    if (matchIdx !== -1) {
      consumed.add(matchIdx);
      next.push(cloneQueueItem(existing[matchIdx]));
      continue;
    }

    next.push({
      id: randomUUID(),
      message: text,
      createdAt: Date.now(),
      images: undefined,
    });
  }

  return next;
}

export class SessionMessageQueueCoordinator {
  constructor(private readonly deps: SessionMessageQueueCoordinatorDeps) {}

  private ensureQueueStore(active: SessionMessageQueueState): SessionMessageQueueStore {
    if (!active.messageQueue) {
      active.messageQueue = {
        version: 0,
        steering: [],
        followUp: [],
      };
    }

    return active.messageQueue;
  }

  private syncFromSdk(active: SessionMessageQueueState): SessionMessageQueueStore {
    const queue = this.ensureQueueStore(active);

    const sdkSteering = active.sdkBackend.session.getSteeringMessages();
    const sdkFollowUp = active.sdkBackend.session.getFollowUpMessages();

    const steeringMatches =
      queue.steering.length === sdkSteering.length &&
      queue.steering.every((item, idx) => item.message === sdkSteering[idx]);
    const followUpMatches =
      queue.followUp.length === sdkFollowUp.length &&
      queue.followUp.every((item, idx) => item.message === sdkFollowUp[idx]);

    if (steeringMatches && followUpMatches) {
      return queue;
    }

    queue.steering = reconcileItemsWithTextQueue(queue.steering, sdkSteering);
    queue.followUp = reconcileItemsWithTextQueue(queue.followUp, sdkFollowUp);
    queue.version += 1;

    return queue;
  }

  private broadcastQueueState(key: string, queue: SessionMessageQueueStore): void {
    this.deps.broadcast(key, {
      type: "queue_state",
      queue: cloneQueueState(queue),
    });
  }

  getQueue(key: string): MessageQueueState {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      throw new Error(`Session not active: ${key}`);
    }

    const queue = this.syncFromSdk(active);
    return cloneQueueState(queue);
  }

  enqueueQueuedMessage(
    key: string,
    kind: MessageQueueKind,
    message: string,
    images?: QueueImageContent[],
    idHint?: string,
  ): void {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

    const queue = this.ensureQueueStore(active);
    const nextItem: MessageQueueItem = {
      id: normalizeQueueId(idHint),
      message: normalizeQueueMessage(message),
      images: queueImagesFromPromptImages(images),
      createdAt: Date.now(),
    };

    if (kind === "steer") {
      queue.steering.push(nextItem);
    } else {
      queue.followUp.push(nextItem);
    }

    queue.version += 1;
    this.broadcastQueueState(key, queue);
  }

  markQueuedMessageStarted(key: string, message: PiMessage): void {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

    const queue = this.ensureQueueStore(active);
    const versionBefore = queue.version;
    const text = extractQueuedUserText(message);

    const reconcileFromSdkIfNeeded = (): void => {
      const synced = this.syncFromSdk(active);
      if (synced.version !== versionBefore) {
        this.broadcastQueueState(key, synced);
      }
    };

    if (!text) {
      reconcileFromSdkIfNeeded();
      return;
    }

    const dequeue = (kind: MessageQueueKind, list: MessageQueueItem[]): MessageQueueItem | null => {
      const index = list.findIndex((item) => item.message === text);
      if (index === -1) {
        return null;
      }

      const [removed] = list.splice(index, 1);
      if (!removed) {
        return null;
      }

      queue.version += 1;
      this.deps.broadcast(key, {
        type: "queue_item_started",
        kind,
        item: cloneQueueItem(removed),
        queueVersion: queue.version,
      });
      this.broadcastQueueState(key, queue);
      return removed;
    };

    const fromSteering = dequeue("steer", queue.steering);
    if (fromSteering) {
      return;
    }

    const fromFollowUp = dequeue("follow_up", queue.followUp);
    if (fromFollowUp) {
      return;
    }

    reconcileFromSdkIfNeeded();
  }

  async setQueue(
    key: string,
    payload: {
      baseVersion: number;
      steering: MessageQueueDraftItem[];
      followUp: MessageQueueDraftItem[];
    },
  ): Promise<MessageQueueState> {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      throw new Error(`Session not active: ${key}`);
    }

    const queue = this.syncFromSdk(active);
    if (payload.baseVersion !== queue.version) {
      throw new Error(
        `Queue version mismatch: expected ${queue.version}, got ${payload.baseVersion}`,
      );
    }

    const steeringItems = normalizeDraftItems(payload.steering);
    const followUpItems = normalizeDraftItems(payload.followUp);

    if (!active.sdkBackend.isStreaming && (steeringItems.length > 0 || followUpItems.length > 0)) {
      throw new Error("Message queue can only contain items while a turn is streaming");
    }

    active.sdkBackend.session.clearQueue();

    for (const item of steeringItems) {
      await active.sdkBackend.session.steer(item.message, promptImagesFromQueue(item.images));
    }

    for (const item of followUpItems) {
      await active.sdkBackend.session.followUp(item.message, promptImagesFromQueue(item.images));
    }

    queue.steering = steeringItems;
    queue.followUp = followUpItems;
    queue.version += 1;

    this.broadcastQueueState(key, queue);
    return cloneQueueState(queue);
  }
}
