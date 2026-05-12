import type { PiMessage } from "./pi-events.js";
import type { SdkBackend } from "./sdk-backend.js";
import { materializeChatAttachments } from "./chat-attachments.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import type { UploadStoreConfigResolved } from "./uploads/local-upload-store.js";
import {
  cloneQueueItem,
  cloneQueueState,
  extractQueuedUserText,
  normalizeDraftItems,
  normalizeQueueId,
  normalizeQueueMessage,
  promptImagesFromQueue,
  queueImagesFromPromptImages,
  type QueueImageContent,
} from "./session-queue-utils.js";
import type {
  ChatAttachmentRef,
  ImageAttachment,
  MessageQueueDraftItem,
  MessageQueueItem,
  MessageQueueKind,
  MessageQueueState,
  ServerMessage,
  Session,
} from "./types.js";

interface QueueStoreItem extends MessageQueueItem {
  /** SDK-only materialized message text. Queue UI/state keeps `message` raw. */
  sdkMessage?: string;
  /** SDK-only image inputs. Queue UI/state keeps `images` as display metadata. */
  sdkImages?: ImageAttachment[];
}

const log = createLogger({ base: { component: "session_queue" } });
const POST_COMPACTION_QUEUE_FLUSH_DELAY_MS = 250;

export interface SessionMessageQueueStore {
  version: number;
  steering: QueueStoreItem[];
  followUp: QueueStoreItem[];
}

export interface SessionMessageQueueState {
  sdkBackend: SdkBackend;
  session: Session;
  messageQueue?: SessionMessageQueueStore;
}

export interface SessionMessageQueueCoordinatorDeps {
  getActiveSession: (key: string) => SessionMessageQueueState | undefined;
  broadcast: (key: string, message: ServerMessage) => void;
  resolveWorkspaceRoot?: (session: Session) => string | null;
  maxTurnAttachmentBytes?: number;
  uploadStoreConfig?: UploadStoreConfigResolved;
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

  private cloneStoreItem(item: QueueStoreItem): QueueStoreItem {
    return {
      ...cloneQueueItem(item),
      ...(item.sdkMessage ? { sdkMessage: item.sdkMessage } : {}),
      ...(item.sdkImages ? { sdkImages: item.sdkImages.map((image) => ({ ...image })) } : {}),
    };
  }

  private sdkQueueText(item: QueueStoreItem): string {
    return item.sdkMessage ?? item.message;
  }

  private reconcileItemsWithSdkTextQueue(
    existing: QueueStoreItem[],
    queuedTexts: readonly string[],
  ): QueueStoreItem[] {
    const next: QueueStoreItem[] = [];
    const consumed = new Set<number>();

    for (const text of queuedTexts) {
      const matchIdx = existing.findIndex(
        (item, idx) => !consumed.has(idx) && this.sdkQueueText(item) === text,
      );

      if (matchIdx !== -1) {
        consumed.add(matchIdx);
        next.push(this.cloneStoreItem(existing[matchIdx]));
        continue;
      }

      next.push({
        id: normalizeQueueId(undefined),
        message: text,
        sdkMessage: text,
        createdAt: Date.now(),
      });
    }

    return next;
  }

  private removedItemsByID(existing: QueueStoreItem[], next: QueueStoreItem[]): MessageQueueItem[] {
    const nextIdCounts = new Map<string, number>();
    for (const item of next) {
      nextIdCounts.set(item.id, (nextIdCounts.get(item.id) ?? 0) + 1);
    }

    const removed: MessageQueueItem[] = [];
    for (const item of existing) {
      const remaining = nextIdCounts.get(item.id) ?? 0;
      if (remaining > 0) {
        nextIdCounts.set(item.id, remaining - 1);
        continue;
      }

      removed.push(cloneQueueItem(item));
    }

    return removed;
  }

  private syncFromSdkWithDiff(active: SessionMessageQueueState): {
    queue: SessionMessageQueueStore;
    changed: boolean;
    removedSteering: MessageQueueItem[];
    removedFollowUp: MessageQueueItem[];
  } {
    const queue = this.ensureQueueStore(active);

    const sdkSteering = active.sdkBackend.session.getSteeringMessages();
    const sdkFollowUp = active.sdkBackend.session.getFollowUpMessages();

    const steeringMatches =
      queue.steering.length === sdkSteering.length &&
      queue.steering.every((item, idx) => this.sdkQueueText(item) === sdkSteering[idx]);
    const followUpMatches =
      queue.followUp.length === sdkFollowUp.length &&
      queue.followUp.every((item, idx) => this.sdkQueueText(item) === sdkFollowUp[idx]);

    if (steeringMatches && followUpMatches) {
      return {
        queue,
        changed: false,
        removedSteering: [],
        removedFollowUp: [],
      };
    }

    const nextSteering = this.reconcileItemsWithSdkTextQueue(queue.steering, sdkSteering);
    const nextFollowUp = this.reconcileItemsWithSdkTextQueue(queue.followUp, sdkFollowUp);

    const removedSteering = this.removedItemsByID(queue.steering, nextSteering);
    const removedFollowUp = this.removedItemsByID(queue.followUp, nextFollowUp);

    queue.steering = nextSteering;
    queue.followUp = nextFollowUp;
    queue.version += 1;

    return {
      queue,
      changed: true,
      removedSteering,
      removedFollowUp,
    };
  }

  private syncFromSdk(active: SessionMessageQueueState): SessionMessageQueueStore {
    return this.syncFromSdkWithDiff(active).queue;
  }

  private queueItemsInDeliveryOrder(
    queue: SessionMessageQueueStore,
  ): Array<{ kind: MessageQueueKind; item: QueueStoreItem; index: number; order: number }> {
    return [
      ...queue.steering.map((item, index) => ({ kind: "steer" as const, item, index, order: 0 })),
      ...queue.followUp.map((item, index) => ({
        kind: "follow_up" as const,
        item,
        index,
        order: 1,
      })),
    ].sort((a, b) => a.item.createdAt - b.item.createdAt || a.order - b.order || a.index - b.index);
  }

  private broadcastQueueState(key: string, queue: SessionMessageQueueStore): void {
    this.deps.broadcast(key, {
      type: "queue_state",
      queue: cloneQueueState(queue),
    });
  }

  /**
   * Clear all queued messages (both steering and follow-up) from the SDK and
   * server-side store, then broadcast the empty queue state to clients.
   *
   * Mirrors what the TUI does on Escape: clear queues before abort so stale
   * messages never leak into the next agent turn.
   */
  clearQueueOnAbort(key: string): void {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

    const queue = this.ensureQueueStore(active);

    // Clear SDK-level queues (AgentSession + Agent internal queues)
    active.sdkBackend.session.clearQueue();

    // Clear server-side tracking
    queue.steering = [];
    queue.followUp = [];
    queue.version += 1;

    this.broadcastQueueState(key, queue);
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
    attachments?: ChatAttachmentRef[],
    idHint?: string,
    sdkMessage?: string,
    sdkImages?: QueueImageContent[],
  ): void {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

    const queue = this.ensureQueueStore(active);
    const nextItem: QueueStoreItem = {
      id: normalizeQueueId(idHint),
      message: normalizeQueueMessage(message),
      images: queueImagesFromPromptImages(images),
      attachments: attachments ? [...attachments] : undefined,
      createdAt: Date.now(),
      sdkMessage: sdkMessage ? normalizeQueueMessage(sdkMessage) : normalizeQueueMessage(message),
      sdkImages: queueImagesFromPromptImages(sdkImages ?? images),
    };

    if (kind === "steer") {
      queue.steering.push(nextItem);
    } else {
      queue.followUp.push(nextItem);
    }

    queue.version += 1;
    this.broadcastQueueState(key, queue);
  }

  private async materializeQueueItemForSdk(
    active: SessionMessageQueueState,
    item: MessageQueueItem,
  ): Promise<QueueStoreItem> {
    if (!item.attachments?.length) {
      return {
        ...cloneQueueItem(item),
        sdkMessage: item.message,
        sdkImages: item.images ? item.images.map((image) => ({ ...image })) : undefined,
      };
    }

    const workspaceRoot = this.deps.resolveWorkspaceRoot?.(active.session);
    if (!workspaceRoot || !active.session.workspaceId) {
      throw new Error("Attachments require a workspace-backed session");
    }

    const materialized = await materializeChatAttachments({
      workspaceRoot,
      workspaceId: active.session.workspaceId,
      sessionId: active.session.id,
      turnId: item.id,
      message: item.message,
      attachments: item.attachments,
      maxTurnBytes: this.deps.maxTurnAttachmentBytes,
      uploadStore: this.deps.uploadStoreConfig,
    });

    const materializedImages = queueImagesFromPromptImages(materialized.imageInputs) ?? [];
    const existingImages = item.images ?? [];

    return {
      ...cloneQueueItem(item),
      message: item.message,
      images: existingImages.length ? existingImages.map((image) => ({ ...image })) : undefined,
      sdkMessage: materialized.message,
      sdkImages:
        materializedImages.length > 0
          ? materializedImages
          : existingImages.length > 0
            ? existingImages.map((image) => ({ ...image }))
            : undefined,
    };
  }

  markQueuedMessageStarted(key: string, message: PiMessage): void {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

    const queue = this.ensureQueueStore(active);
    const text = extractQueuedUserText(message);

    const reconcileFromSdkIfNeeded = (): void => {
      const synced = this.syncFromSdkWithDiff(active);
      if (!synced.changed) {
        return;
      }

      for (const item of synced.removedSteering) {
        this.deps.broadcast(key, {
          type: "queue_item_started",
          kind: "steer",
          item: cloneQueueItem(item),
          queueVersion: synced.queue.version,
        });
      }

      for (const item of synced.removedFollowUp) {
        this.deps.broadcast(key, {
          type: "queue_item_started",
          kind: "follow_up",
          item: cloneQueueItem(item),
          queueVersion: synced.queue.version,
        });
      }

      this.broadcastQueueState(key, synced.queue);
    };

    if (!text) {
      reconcileFromSdkIfNeeded();
      return;
    }

    const dequeue = (kind: MessageQueueKind, list: QueueStoreItem[]): MessageQueueItem | null => {
      const index = list.findIndex(
        (item) => item.message === text || this.sdkQueueText(item) === text,
      );
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

  schedulePostCompactionQueueFlush(key: string): void {
    const timer = setTimeout(() => {
      void this.flushIdleQueuedMessages(key).catch((error: unknown) => {
        log.error("session_queue.post_compaction_flush.failed", {
          sessionId: key,
          error: safeErrorMessage(error),
        });
      });
    }, POST_COMPACTION_QUEUE_FLUSH_DELAY_MS);
    timer.unref?.();
  }

  async flushIdleQueuedMessages(key: string): Promise<boolean> {
    const active = this.deps.getActiveSession(key);
    if (!active || active.sdkBackend.isStreaming) {
      return false;
    }

    const synced = this.syncFromSdkWithDiff(active);
    const queue = synced.queue;
    if (synced.changed) {
      this.broadcastQueueState(key, queue);
    }

    const ordered = this.queueItemsInDeliveryOrder(queue);
    const first = ordered[0];
    if (!first) {
      return false;
    }

    const firstItem = this.cloneStoreItem(first.item);
    const remainingSteering = queue.steering
      .filter((_, index) => first.kind !== "steer" || index !== first.index)
      .map((item) => this.cloneStoreItem(item));
    const remainingFollowUp = queue.followUp
      .filter((_, index) => first.kind !== "follow_up" || index !== first.index)
      .map((item) => this.cloneStoreItem(item));

    active.sdkBackend.session.clearQueue();

    queue.steering = remainingSteering;
    queue.followUp = remainingFollowUp;
    queue.version += 1;

    this.deps.broadcast(key, {
      type: "queue_item_started",
      kind: first.kind,
      item: cloneQueueItem(firstItem),
      queueVersion: queue.version,
    });

    active.sdkBackend.prompt(firstItem.sdkMessage ?? firstItem.message, {
      images: promptImagesFromQueue(firstItem.sdkImages ?? firstItem.images),
    });

    for (const item of remainingSteering) {
      await active.sdkBackend.session.steer(
        item.sdkMessage ?? item.message,
        promptImagesFromQueue(item.sdkImages ?? item.images),
      );
    }

    for (const item of remainingFollowUp) {
      await active.sdkBackend.session.followUp(
        item.sdkMessage ?? item.message,
        promptImagesFromQueue(item.sdkImages ?? item.images),
      );
    }

    this.broadcastQueueState(key, queue);
    return true;
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
    const hasNextItems = steeringItems.length > 0 || followUpItems.length > 0;
    const hasExistingItems = queue.steering.length > 0 || queue.followUp.length > 0;
    const shouldFlushAfterSave = !active.sdkBackend.isStreaming && hasNextItems && hasExistingItems;

    if (!active.sdkBackend.isStreaming && hasNextItems && !hasExistingItems) {
      throw new Error("Message queue can only contain items while a turn is streaming");
    }

    const sdkSteeringItems = await Promise.all(
      steeringItems.map((item) => this.materializeQueueItemForSdk(active, item)),
    );
    const sdkFollowUpItems = await Promise.all(
      followUpItems.map((item) => this.materializeQueueItemForSdk(active, item)),
    );

    active.sdkBackend.session.clearQueue();

    for (const item of sdkSteeringItems) {
      await active.sdkBackend.session.steer(
        item.sdkMessage ?? item.message,
        promptImagesFromQueue(item.sdkImages ?? item.images),
      );
    }

    for (const item of sdkFollowUpItems) {
      await active.sdkBackend.session.followUp(
        item.sdkMessage ?? item.message,
        promptImagesFromQueue(item.sdkImages ?? item.images),
      );
    }

    queue.steering = sdkSteeringItems;
    queue.followUp = sdkFollowUpItems;
    queue.version += 1;

    this.broadcastQueueState(key, queue);

    if (shouldFlushAfterSave) {
      await this.flushIdleQueuedMessages(key);
    }

    return cloneQueueState(queue);
  }
}
