import type { PiMessage } from "./pi-events.js";
import type { SdkBackend } from "./sdk-backend.js";
import {
  cloneQueueItem,
  cloneQueueState,
  extractQueuedUserText,
  normalizeDraftItems,
  normalizeQueueId,
  normalizeQueueMessage,
  promptImagesFromQueue,
  queueImagesFromPromptImages,
  reconcileItemsWithTextQueue,
  type QueueImageContent,
} from "./session-queue-utils.js";
import type {
  MessageQueueDraftItem,
  MessageQueueItem,
  MessageQueueKind,
  MessageQueueState,
  ServerMessage,
} from "./types.js";

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

  private removedItemsByID(
    existing: MessageQueueItem[],
    next: MessageQueueItem[],
  ): MessageQueueItem[] {
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
      queue.steering.every((item, idx) => item.message === sdkSteering[idx]);
    const followUpMatches =
      queue.followUp.length === sdkFollowUp.length &&
      queue.followUp.every((item, idx) => item.message === sdkFollowUp[idx]);

    if (steeringMatches && followUpMatches) {
      return {
        queue,
        changed: false,
        removedSteering: [],
        removedFollowUp: [],
      };
    }

    const nextSteering = reconcileItemsWithTextQueue(queue.steering, sdkSteering);
    const nextFollowUp = reconcileItemsWithTextQueue(queue.followUp, sdkFollowUp);

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
