import type { PiMessage } from "./pi-events.js";
import {
  QUEUE_RECONCILIATION_REQUIRED_ERROR,
  QueuedModelTurnsAuthorityError,
  QueuedModelTurnsReconciliationError,
  type QueuedModelTurnBatch,
  type QueuedModelTurnsAuthority,
  type SdkBackend,
} from "./sdk-backend.js";
import { materializeChatAttachments } from "./chat-attachments.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import type { UploadStoreConfigResolved } from "./uploads/local-upload-store.js";
import {
  assertQueueBaseVersion,
  cloneQueueItem,
  cloneQueueState,
  dequeueQueueItemByText,
  extractQueuedUserText,
  normalizeDraftItems,
  normalizeQueueId,
  normalizeQueueMessage,
  nextQueueVersion,
  promptImagesFromQueue,
  queueImagesFromPromptImages,
  queueItemStartedMessage,
  queueStateMessage,
  type QueueImageContent,
} from "./session-queue-utils.js";
import type { SessionRuntimeTransactionPermit } from "./session-runtime-transaction.js";
import type {
  ChatAttachmentRef,
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
  /** SDK-only image inputs. Public queue state never carries base64 image bytes. */
  sdkImages?: QueueImageContent[];
}

const log = createLogger({ base: { component: "session_queue" } });
const POST_COMPACTION_QUEUE_FLUSH_DELAY_MS = 250;

export interface SessionMessageQueueStore {
  version: number;
  steering: QueueStoreItem[];
  followUp: QueueStoreItem[];
  reconciliationRequired?: boolean;
}

export interface SessionMessageQueueState {
  sdkBackend: SdkBackend;
  session: Session;
  messageQueue?: SessionMessageQueueStore;
}

export interface SessionAbortQueueClear {
  readonly key: string;
}

export interface SessionMessageQueueCoordinatorDeps {
  getActiveSession: (key: string) => SessionMessageQueueState | undefined;
  broadcast: (key: string, message: ServerMessage) => void;
  resolveWorkspaceRoot?: (session: Session) => string | null;
  maxTurnAttachmentBytes?: number;
  uploadStoreConfig?: UploadStoreConfigResolved;
}

export class SessionMessageQueueCoordinator {
  private readonly abortQueueSnapshots = new WeakMap<
    SessionAbortQueueClear,
    {
      active: SessionMessageQueueState;
      steering: QueueStoreItem[];
      followUp: QueueStoreItem[];
      reconciliationRequired: boolean;
    }
  >();

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

  private assertQueueReconciled(
    active: SessionMessageQueueState,
    queue: SessionMessageQueueStore,
  ): void {
    if (queue.reconciliationRequired || active.sdkBackend.isQueueReconciliationRequired) {
      throw new Error(QUEUE_RECONCILIATION_REQUIRED_ERROR);
    }
  }

  assertModelTurnAdmissionAllowed(key: string): void {
    const active = this.deps.getActiveSession(key);
    if (!active) throw new Error(`Session not active: ${key}`);
    const queue = this.ensureQueueStore(active);
    this.assertQueueReconciled(active, queue);
    // Once exhausted, a turn could consume or enqueue intent that cannot be
    // assigned a distinct CAS version. Fail before Pi accepts the turn.
    nextQueueVersion(queue.version);
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
    const version = nextQueueVersion(queue.version);

    queue.steering = nextSteering;
    queue.followUp = nextFollowUp;
    queue.version = version;

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
    this.deps.broadcast(key, queueStateMessage(queue));
  }

  /**
   * Clear all queued messages (both steering and follow-up) from the SDK and
   * server-side store, then broadcast the empty queue state to clients.
   *
   * Mirrors what the TUI does on Escape: clear queues before abort so stale
   * messages never leak into the next agent turn.
   */
  clearQueueOnAbort(
    key: string,
    permit: SessionRuntimeTransactionPermit,
  ): SessionAbortQueueClear | undefined {
    const active = this.deps.getActiveSession(key);
    if (!active) return undefined;
    const queue = this.ensureQueueStore(active);
    this.assertQueueReconciled(active, queue);
    const clearedVersion = nextQueueVersion(queue.version);
    // A failed abort restores the prior intent as a second observable mutation.
    // Reserve that version before clearing Pi so compensation cannot overflow.
    nextQueueVersion(clearedVersion);
    const clear = Object.freeze({ key });
    this.abortQueueSnapshots.set(clear, {
      active,
      steering: queue.steering.map((item) => this.cloneStoreItem(item)),
      followUp: queue.followUp.map((item) => this.cloneStoreItem(item)),
      reconciliationRequired: queue.reconciliationRequired === true,
    });

    try {
      active.sdkBackend.clearQueuedModelTurns(permit);
    } catch (error) {
      this.abortQueueSnapshots.delete(clear);
      throw error;
    }

    queue.reconciliationRequired = false;
    queue.steering = [];
    queue.followUp = [];
    queue.version = clearedVersion;
    this.broadcastQueueState(key, queue);
    return clear;
  }

  acceptQueueClearOnAbort(clear: SessionAbortQueueClear): void {
    this.abortQueueSnapshots.delete(clear);
  }

  async restoreQueueAfterAbortFailure(
    clear: SessionAbortQueueClear,
    permit: SessionRuntimeTransactionPermit,
  ): Promise<void> {
    const snapshot = this.abortQueueSnapshots.get(clear);
    if (!snapshot) return;
    this.abortQueueSnapshots.delete(clear);

    const active = this.deps.getActiveSession(clear.key);
    if (active !== snapshot.active) return;
    const queue = this.ensureQueueStore(active);
    const restoredVersion = nextQueueVersion(queue.version);
    let reconciliationRequired = snapshot.reconciliationRequired;
    try {
      await active.sdkBackend.replaceQueuedModelTurns(
        {
          steering: this.queueBatchItems(snapshot.steering),
          followUp: this.queueBatchItems(snapshot.followUp),
        },
        { steering: [], followUp: [] },
        permit,
      );
    } catch (error) {
      reconciliationRequired = true;
      log.error("session_queue.abort_rollback.failed", {
        sessionId: active.session.id,
        error: safeErrorMessage(error),
      });
    }

    // The last acknowledged Oppi intent remains authoritative even if Pi
    // cannot replay it. Reconciliation then blocks reads until setQueue retries
    // from this preserved version instead of silently claiming an empty queue.
    queue.reconciliationRequired = reconciliationRequired;
    queue.steering = snapshot.steering;
    queue.followUp = snapshot.followUp;
    queue.version = restoredVersion;
    this.broadcastQueueState(clear.key, queue);
  }

  getQueue(key: string): MessageQueueState {
    const active = this.deps.getActiveSession(key);
    if (!active) throw new Error(`Session not active: ${key}`);
    const queue = this.ensureQueueStore(active);
    this.assertQueueReconciled(active, queue);
    // SDK clear/replay is invisible to readers until the Oppi queue commits.
    if (active.sdkBackend.isRuntimeLifecycleTransactionExclusive) {
      return cloneQueueState(queue);
    }
    return cloneQueueState(this.syncFromSdk(active));
  }

  enqueueQueuedMessage(
    key: string,
    kind: MessageQueueKind,
    message: string,
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
      attachments: attachments ? [...attachments] : undefined,
      createdAt: Date.now(),
      sdkMessage: sdkMessage ? normalizeQueueMessage(sdkMessage) : normalizeQueueMessage(message),
      sdkImages: queueImagesFromPromptImages(sdkImages),
    };

    const version = nextQueueVersion(queue.version);
    if (kind === "steer") {
      queue.steering.push(nextItem);
    } else {
      queue.followUp.push(nextItem);
    }

    queue.version = version;
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
      };
    }

    const workspaceRoot = this.deps.resolveWorkspaceRoot?.(active.session);
    if (!workspaceRoot) {
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

    return {
      ...cloneQueueItem(item),
      message: item.message,
      sdkMessage: materialized.message,
      sdkImages: materializedImages.length > 0 ? materializedImages : undefined,
    };
  }

  markQueuedMessageStarted(key: string, message: PiMessage): void {
    const active = this.deps.getActiveSession(key);
    if (!active || active.sdkBackend.isRuntimeLifecycleTransactionExclusive) return;

    const queue = this.ensureQueueStore(active);
    if (queue.reconciliationRequired || active.sdkBackend.isQueueReconciliationRequired) return;
    const text = extractQueuedUserText(message);

    const reconcileFromSdkIfNeeded = (): void => {
      const synced = this.syncFromSdkWithDiff(active);
      if (!synced.changed) {
        return;
      }

      for (const item of synced.removedSteering) {
        this.deps.broadcast(
          key,
          queueItemStartedMessage({
            kind: "steer",
            item,
            queueVersion: synced.queue.version,
          }),
        );
      }

      for (const item of synced.removedFollowUp) {
        this.deps.broadcast(
          key,
          queueItemStartedMessage({
            kind: "follow_up",
            item,
            queueVersion: synced.queue.version,
          }),
        );
      }

      this.broadcastQueueState(key, synced.queue);
    };

    if (!text) {
      reconcileFromSdkIfNeeded();
      return;
    }

    const started = dequeueQueueItemByText(
      queue,
      text,
      (item, value) => item.message === value || this.sdkQueueText(item) === value,
    );
    if (started) {
      this.deps.broadcast(key, queueItemStartedMessage(started));
      this.broadcastQueueState(key, queue);
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

  private async replaceQueuedModelTurns(
    active: SessionMessageQueueState,
    queue: SessionMessageQueueStore,
    batch: QueuedModelTurnBatch,
    rollback: QueuedModelTurnBatch,
    permit: SessionRuntimeTransactionPermit,
    authority?: QueuedModelTurnsAuthority,
  ): Promise<QueuedModelTurnsAuthority | undefined> {
    try {
      return await active.sdkBackend.replaceQueuedModelTurns(batch, rollback, permit, authority);
    } catch (error) {
      if (error instanceof QueuedModelTurnsReconciliationError) {
        queue.reconciliationRequired = true;
        log.error("session_queue.reconciliation_required", {
          sessionId: active.session.id,
          error: safeErrorMessage(error),
        });
      }
      throw error;
    }
  }

  private rejectChangedQueueAuthority(
    key: string,
    active: SessionMessageQueueState,
    queue: SessionMessageQueueStore,
    baseVersion: number,
    error: QueuedModelTurnsAuthorityError,
    replayedSteering: QueueStoreItem[],
    replayedFollowUp: QueueStoreItem[],
  ): never {
    const basisSteering = error.phase === "before_replay" ? queue.steering : replayedSteering;
    const basisFollowUp = error.phase === "before_replay" ? queue.followUp : replayedFollowUp;
    const nextSteering = this.reconcileItemsWithSdkTextQueue(
      basisSteering,
      active.sdkBackend.session.getSteeringMessages(),
    );
    const nextFollowUp = this.reconcileItemsWithSdkTextQueue(
      basisFollowUp,
      active.sdkBackend.session.getFollowUpMessages(),
    );
    const removedSteering = this.removedItemsByID(basisSteering, nextSteering);
    const removedFollowUp = this.removedItemsByID(basisFollowUp, nextFollowUp);
    const version = nextQueueVersion(queue.version);

    queue.reconciliationRequired = false;
    queue.steering = nextSteering;
    queue.followUp = nextFollowUp;
    queue.version = version;

    for (const item of removedSteering) {
      this.deps.broadcast(
        key,
        queueItemStartedMessage({ kind: "steer", item, queueVersion: queue.version }),
      );
    }
    for (const item of removedFollowUp) {
      this.deps.broadcast(
        key,
        queueItemStartedMessage({ kind: "follow_up", item, queueVersion: queue.version }),
      );
    }
    this.broadcastQueueState(key, queue);

    log.warn("session_queue.authority_changed", {
      sessionId: active.session.id,
      phase: error.phase,
      baseVersion,
      authoritativeVersion: queue.version,
    });
    throw new Error(`Queue version mismatch: expected ${queue.version}, got ${baseVersion}`);
  }

  async flushIdleQueuedMessages(key: string): Promise<boolean> {
    const active = this.deps.getActiveSession(key);
    if (!active) return false;
    return active.sdkBackend.withRuntimeLifecycleTransaction("queue flush", (permit) => {
      const current = this.deps.getActiveSession(key);
      if (current !== active) throw new Error(`Session not active: ${key}`);
      return this.flushIdleQueuedMessagesInTransaction(key, active, permit);
    });
  }

  private async flushIdleQueuedMessagesInTransaction(
    key: string,
    active: SessionMessageQueueState,
    permit: SessionRuntimeTransactionPermit,
  ): Promise<boolean> {
    const storedQueue = this.ensureQueueStore(active);
    this.assertQueueReconciled(active, storedQueue);
    if (active.sdkBackend.isStreaming) return false;

    const synced = this.syncFromSdkWithDiff(active);
    const queue = synced.queue;
    if (synced.changed) this.broadcastQueueState(key, queue);
    const first = this.queueItemsInDeliveryOrder(queue)[0];
    if (!first) return false;

    const firstItem = this.cloneStoreItem(first.item);
    const version = nextQueueVersion(queue.version);
    const previous = this.queueBatch(queue);
    const remainingSteering = queue.steering
      .filter((_, index) => first.kind !== "steer" || index !== first.index)
      .map((item) => this.cloneStoreItem(item));
    const remainingFollowUp = queue.followUp
      .filter((_, index) => first.kind !== "follow_up" || index !== first.index)
      .map((item) => this.cloneStoreItem(item));

    await this.replaceQueuedModelTurns(
      active,
      queue,
      {
        prompt: {
          message: firstItem.sdkMessage ?? firstItem.message,
          images: promptImagesFromQueue(firstItem.sdkImages),
        },
        steering: this.queueBatchItems(remainingSteering),
        followUp: this.queueBatchItems(remainingFollowUp),
      },
      previous,
      permit,
    );

    // Commit and emit started only after Pi's prompt preflight accepts.
    queue.steering = remainingSteering;
    queue.followUp = remainingFollowUp;
    queue.version = version;
    this.deps.broadcast(
      key,
      queueItemStartedMessage({ kind: first.kind, item: firstItem, queueVersion: queue.version }),
    );
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
    if (!active) throw new Error(`Session not active: ${key}`);
    return active.sdkBackend.withRuntimeLifecycleTransaction(
      "queue replacement",
      async (permit) => {
        const current = this.deps.getActiveSession(key);
        if (current !== active) throw new Error(`Session not active: ${key}`);

        // CAS validation, attachment materialization, SDK replay, Oppi commit, and
        // broadcast are one exclusive transaction. A same-base waiter validates
        // only after the preceding commit and deterministically becomes stale.
        const storedQueue = this.ensureQueueStore(active);
        const queue =
          storedQueue.reconciliationRequired || active.sdkBackend.isQueueReconciliationRequired
            ? storedQueue
            : this.syncFromSdk(active);
        assertQueueBaseVersion(queue, payload.baseVersion);
        const authority = active.sdkBackend.captureQueuedModelTurnsAuthority(permit);
        const steeringItems = normalizeDraftItems(payload.steering);
        const followUpItems = normalizeDraftItems(payload.followUp);
        const hasNextItems = steeringItems.length > 0 || followUpItems.length > 0;
        const hasExistingItems = queue.steering.length > 0 || queue.followUp.length > 0;
        const shouldFlushAfterSave =
          !active.sdkBackend.isStreaming && hasNextItems && hasExistingItems;
        const replacementVersion = nextQueueVersion(queue.version);
        if (shouldFlushAfterSave) {
          // Reserve the automatic flush version before replaying anything into Pi.
          nextQueueVersion(replacementVersion);
        }

        if (!active.sdkBackend.isStreaming && hasNextItems && !hasExistingItems) {
          throw new Error("Message queue can only contain items while a turn is streaming");
        }

        const sdkSteeringItems = await Promise.all(
          steeringItems.map((item) => this.materializeQueueItemForSdk(active, item)),
        );
        const sdkFollowUpItems = await Promise.all(
          followUpItems.map((item) => this.materializeQueueItemForSdk(active, item)),
        );
        try {
          const replayAuthority = await this.replaceQueuedModelTurns(
            active,
            queue,
            {
              steering: this.queueBatchItems(sdkSteeringItems),
              followUp: this.queueBatchItems(sdkFollowUpItems),
            },
            this.queueBatch(queue),
            permit,
            authority,
          );
          if (!replayAuthority) {
            throw new Error("Queue replacement completed without an authority token");
          }
          // No await is allowed between this final check and the Oppi commit.
          active.sdkBackend.assertQueuedModelTurnsAuthority(replayAuthority, permit);
        } catch (error) {
          if (error instanceof QueuedModelTurnsAuthorityError) {
            this.rejectChangedQueueAuthority(
              key,
              active,
              queue,
              payload.baseVersion,
              error,
              sdkSteeringItems,
              sdkFollowUpItems,
            );
          }
          throw error;
        }

        queue.reconciliationRequired = false;
        queue.steering = sdkSteeringItems;
        queue.followUp = sdkFollowUpItems;
        queue.version = replacementVersion;
        this.broadcastQueueState(key, queue);

        if (shouldFlushAfterSave) {
          await this.flushIdleQueuedMessagesInTransaction(key, active, permit);
        }
        return cloneQueueState(queue);
      },
    );
  }

  private queueBatchItems(items: QueueStoreItem[]): Array<{
    message: string;
    images?: QueueImageContent[];
  }> {
    return items.map((item) => ({
      message: item.sdkMessage ?? item.message,
      images: promptImagesFromQueue(item.sdkImages),
    }));
  }

  private queueBatch(queue: SessionMessageQueueStore): {
    steering: Array<{ message: string; images?: QueueImageContent[] }>;
    followUp: Array<{ message: string; images?: QueueImageContent[] }>;
  } {
    return {
      steering: this.queueBatchItems(queue.steering),
      followUp: this.queueBatchItems(queue.followUp),
    };
  }
}
