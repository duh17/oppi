import type { PiMessage } from "./pi-events.js";
import type { AgentBackend } from "./agent-backend.js";
import {
  QUEUE_RECONCILIATION_REQUIRED_ERROR,
  QueuedModelTurnsReconciliationError,
  type QueuedModelTurnBatch,
} from "./sdk-backend.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import type { UploadStoreConfigResolved } from "./uploads/local-upload-store.js";
import {
  cloneQueueItem,
  cloneQueueState,
  dequeueQueueItemByText,
  extractQueuedUserText,
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
  sdkBackend: AgentBackend;
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
    if (active.sdkBackend.nativeMessageQueue) return;
    const queue = this.ensureQueueStore(active);
    this.assertQueueReconciled(active, queue);
    // Once exhausted, a turn could consume or enqueue intent that cannot be
    // assigned a distinct display version. Fail before Pi accepts the turn.
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

    const { steering: sdkSteering, followUp: sdkFollowUp } = active.sdkBackend.queuedMessages();

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
    // Durable abort owns inbox withdrawal in the same operation as cancellation.
    // Individual withdrawals use the native inbox operation instead.
    if (active.sdkBackend.abortClearsQueuedModelTurns) return undefined;
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
    // cannot replay it. Reconciliation then blocks reads rather than silently
    // claiming an empty queue.
    queue.reconciliationRequired = reconciliationRequired;
    queue.steering = snapshot.steering;
    queue.followUp = snapshot.followUp;
    queue.version = restoredVersion;
    this.broadcastQueueState(clear.key, queue);
  }

  /** Native inbox changes (including abort) are authoritative, even while busy. */
  refreshQueuedMessages(key: string): void {
    const active = this.deps.getActiveSession(key);
    if (!active) return;
    if (active.sdkBackend.nativeMessageQueue) {
      void active.sdkBackend
        .nativeMessageQueue()
        .then((queue) => {
          if (this.deps.getActiveSession(key) === active)
            this.deps.broadcast(key, queueStateMessage(queue));
        })
        .catch((error: unknown) =>
          log.error("session_queue.native_refresh.failed", { error: safeErrorMessage(error) }),
        );
      return;
    }
    if (active.sdkBackend.isRuntimeLifecycleTransactionExclusive) return;
    this.broadcastQueueState(key, this.syncFromSdk(active));
  }

  getQueue(key: string): MessageQueueState | Promise<MessageQueueState> {
    const active = this.deps.getActiveSession(key);
    if (!active) throw new Error(`Session not active: ${key}`);
    if (active.sdkBackend.nativeMessageQueue) return active.sdkBackend.nativeMessageQueue();
    const queue = this.ensureQueueStore(active);
    this.assertQueueReconciled(active, queue);
    // SDK clear/replay is invisible to readers until the Oppi queue commits.
    if (active.sdkBackend.isRuntimeLifecycleTransactionExclusive) {
      return cloneQueueState(queue);
    }
    return cloneQueueState(this.syncFromSdk(active));
  }

  private makeQueuedItem(
    message: string,
    attachments?: ChatAttachmentRef[],
    idHint?: string,
    sdkMessage?: string,
    sdkImages?: QueueImageContent[],
  ): QueueStoreItem {
    return {
      id: normalizeQueueId(idHint),
      message: normalizeQueueMessage(message),
      attachments: attachments ? [...attachments] : undefined,
      createdAt: Date.now(),
      sdkMessage: sdkMessage ? normalizeQueueMessage(sdkMessage) : normalizeQueueMessage(message),
      sdkImages: queueImagesFromPromptImages(sdkImages),
    };
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
    const nextItem = this.makeQueuedItem(message, attachments, idHint, sdkMessage, sdkImages);

    const version = nextQueueVersion(queue.version);
    if (kind === "steer") {
      queue.steering.push(nextItem);
    } else {
      queue.followUp.push(nextItem);
    }

    queue.version = version;
    this.broadcastQueueState(key, queue);
  }

  markQueuedMessageStarted(key: string, message: PiMessage): void {
    const active = this.deps.getActiveSession(key);
    if (
      !active ||
      active.sdkBackend.nativeMessageQueue ||
      active.sdkBackend.isRuntimeLifecycleTransactionExclusive
    )
      return;

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
  ): Promise<void> {
    try {
      return await active.sdkBackend.replaceQueuedModelTurns(batch, rollback, permit);
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

  async flushIdleQueuedMessages(key: string): Promise<boolean> {
    const active = this.deps.getActiveSession(key);
    if (!active || active.sdkBackend.retainsIdleQueueUntilAdmission) return false;
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

  removeQueuedMessage(key: string, itemId: string): Promise<MessageQueueState> {
    return this.withdrawQueue(key, itemId);
  }

  takeQueue(key: string): Promise<MessageQueueState> {
    return this.withdrawQueue(key);
  }

  private async withdrawQueue(key: string, itemId?: string): Promise<MessageQueueState> {
    const active = this.deps.getActiveSession(key);
    if (!active) throw new Error(`Session not active: ${key}`);
    return active.sdkBackend.withRuntimeLifecycleTransaction("queue withdrawal", async (permit) => {
      if (this.deps.getActiveSession(key) !== active) throw new Error(`Session not active: ${key}`);
      if (active.sdkBackend.withdrawNativeQueue) {
        const withdrawn = await active.sdkBackend.withdrawNativeQueue(itemId, permit);
        const current = await active.sdkBackend.nativeMessageQueue!();
        this.deps.broadcast(key, queueStateMessage(current));
        return itemId === undefined ? withdrawn : current;
      }
      this.assertQueueReconciled(active, this.ensureQueueStore(active));
      const queue = this.syncFromSdk(active);
      const selected = (items: QueueStoreItem[]) =>
        items.filter((item) => itemId === undefined || item.id === itemId);
      const withdrawn: MessageQueueState = {
        version: queue.version,
        steering: [],
        followUp: [],
      };
      // Snapshot and clear are adjacent synchronous operations. The lifecycle
      // transaction excludes Oppi admissions, while native Pi remains the
      // authority for anything consumed during replay of the remaining items.
      const version = nextQueueVersion(queue.version);
      const remaining = (items: QueueStoreItem[]) =>
        items.filter((item) => itemId !== undefined && item.id !== itemId);
      const steering = remaining(queue.steering);
      const followUp = remaining(queue.followUp);
      withdrawn.steering = selected(queue.steering).map(cloneQueueItem);
      withdrawn.followUp = selected(queue.followUp).map(cloneQueueItem);
      if (!withdrawn.steering.length && !withdrawn.followUp.length)
        return itemId === undefined ? withdrawn : cloneQueueState(queue);
      await this.replaceQueuedModelTurns(
        active,
        queue,
        {
          steering: this.queueBatchItems(steering),
          followUp: this.queueBatchItems(followUp),
        },
        this.queueBatch(queue),
        permit,
      );
      queue.steering = steering;
      queue.followUp = followUp;
      queue.version = version;
      this.broadcastQueueState(key, this.syncFromSdk(active));
      withdrawn.version = queue.version;
      return itemId === undefined ? withdrawn : cloneQueueState(queue);
    });
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
