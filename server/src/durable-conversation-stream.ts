/**
 * Durable conversation stream (experimental): a client replica of one
 * conversation's `{ entries, docs }`.
 *
 * One `ConversationRoom` per attached conversation holds the active entries and
 * the client-visible documents, advanced synchronously from the Harness commit
 * publications, so it never holds half a commit. Each attached socket has a
 * `ConversationStreamSubscription` that remembers what it sent and, at most every
 * 100 ms, sends what changed: new entries plus Chord ops per document
 * (`diffRevisions`, so grown text is an append). A head move (reset or
 * compaction) or an unusable resume cursor sends a full snapshot instead.
 */
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { diffRevisions } from "@earendil-works/chord/delta";
import type {
  CommitPublication,
  ConversationId,
  EntryId,
  EntryRecord,
  Harness,
  JsonObject,
} from "@earendil-works/pi-durable";
import {
  CONVERSATION_CLIENT_DOCS,
  projectEntry,
  renderToolCall,
  toolCallsOf,
  type ToolPresenter,
} from "./durable-conversation-view.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import type { MobileRendererRegistry } from "./mobile-renderer.js";
import type {
  ConversationDocOp,
  ConversationEntryView,
  ConversationStreamServerMessage,
  ConversationToolCallView,
} from "./types.js";

const log = createLogger({ base: { component: "durable-conversation-stream" } });

/** Durable commits partials and tool output at most this often; faster frames gain nothing. */
export const CONVERSATION_FRAME_INTERVAL_MS = 100;

const CLIENT_DOC_KINDS = new Set(CONVERSATION_CLIENT_DOCS.map((spec) => spec.kind));

type SendFrame = (frame: ConversationStreamServerMessage) => void;

class ConversationRoom implements ToolPresenter {
  readonly subscribers = new Set<ConversationStreamSubscription>();
  closed = false;
  /** Active entries in display order: the head entry first, when there is one. */
  entries: EntryRecord[] = [];
  /** Id of the newest head entry, or 0. */
  head = 0;
  /** Largest active entry id. */
  tip = 0;
  hasOlder = false;
  private readonly ids = new Set<number>();
  private readonly committed = new Map<string, JsonObject>();
  private readonly projected = new Map<string, JsonObject>();
  private readonly dirty = new Set<string>();
  private readonly entryViews = new Map<number, ConversationEntryView>();
  private readonly calls = new Map<string, { name: string; args: unknown }>();
  private readonly callViews = new WeakMap<
    object,
    { name: string; view: ConversationToolCallView }
  >();
  /** Publications that arrive while the room loads; replayed over the loaded state. */
  private pending: CommitPublication[] | undefined = [];
  private readonly detach: Array<() => void> = [];

  private constructor(
    private readonly harness: Harness,
    readonly conversationId: ConversationId,
    private readonly renderers: MobileRendererRegistry,
  ) {}

  static async open(
    harness: Harness,
    conversationId: ConversationId,
    renderers: MobileRendererRegistry,
  ): Promise<ConversationRoom> {
    const room = new ConversationRoom(harness, conversationId, renderers);
    // Subscribe before reading so no commit falls between the read and the listener.
    room.detach.push(harness.subscribeCommits((publication) => room.publish(publication)));
    room.detach.push(harness.subscribeClose(() => room.close()));
    try {
      await room.load();
    } catch (error) {
      room.close();
      throw error;
    }
    return room;
  }

  private async load(): Promise<void> {
    const conversation = await this.harness.conversation(this.conversationId, context);
    if (!conversation) throw new Error(`Durable conversation ${this.conversationId} is missing`);
    const state = await conversation.viewState(context);
    const view = state.value;
    state.dispose();
    for (const entry of view.entries) this.addEntry(entry);
    for (const spec of CONVERSATION_CLIENT_DOCS) {
      const value =
        view.docs[spec.kind] ??
        (await this.harness.snapshot(spec.doc, this.conversationId, context));
      if (value) this.setDoc(spec.kind, value);
    }
    let first: number | undefined;
    for (const entry of this.entries) first = Math.min(first ?? entry.id, entry.id);
    if (first !== undefined && first > 1) {
      const older = await conversation.entries(
        { maxEntryId: (first - 1) as EntryId },
        1,
        undefined,
        context,
      );
      this.hasOlder ||= older.items.length > 0;
    }
    // Replaying commits the read already saw is idempotent: entries are keyed by id,
    // head moves re-select the same suffix, and each document ends at its newest value.
    const pending = this.pending ?? [];
    this.pending = undefined;
    for (const publication of pending) this.apply(publication);
  }

  /** Commit listener: synchronous, never throws, never calls Session APIs. */
  private publish(publication: CommitPublication): void {
    if (this.closed) return;
    if (this.pending) {
      this.pending.push(publication);
      return;
    }
    try {
      if (!this.apply(publication)) return;
    } catch (error) {
      log.error("conversation_stream.apply_failed", {
        conversationId: this.conversationId,
        error: safeErrorMessage(error),
      });
      return;
    }
    for (const subscriber of this.subscribers) subscriber.notify();
  }

  private apply(publication: CommitPublication): boolean {
    let changed = false;
    const entries: EntryRecord[] = [];
    for (const change of publication.changes) {
      if (change.type === "entry") {
        if (change.value.conversationId === this.conversationId) entries.push(change.value);
        continue;
      }
      if (
        change.type !== "document" ||
        change.conversationId !== this.conversationId ||
        change.record.key !== undefined ||
        !CLIENT_DOC_KINDS.has(change.record.kind)
      )
        continue;
      if (change.value) this.setDoc(change.record.kind, change.value);
      else {
        this.committed.delete(change.record.kind);
        this.projected.delete(change.record.kind);
        this.dirty.delete(change.record.kind);
      }
      changed = true;
    }
    entries.sort((left, right) => left.id - right.id);
    for (const entry of entries) changed = this.addEntry(entry) || changed;
    return changed;
  }

  private setDoc(kind: string, value: JsonObject): void {
    this.committed.set(kind, value);
    this.dirty.add(kind);
  }

  private addEntry(entry: EntryRecord): boolean {
    const from = entry.head;
    if (from !== undefined) {
      if (entry.id === this.head) return false;
      // A head entry keeps the entries from its head, which are always a suffix, and goes first.
      const kept = this.entries.filter(
        (candidate) => candidate.head === undefined && candidate.id >= from,
      );
      if (this.head !== 0 || kept.length < this.entries.length) this.hasOlder = true;
      this.entries = [entry, ...kept];
      this.head = entry.id;
      this.ids.clear();
      this.calls.clear();
      for (const id of [...this.entryViews.keys()])
        if (!kept.some((candidate) => candidate.id === id)) this.entryViews.delete(id);
      for (const candidate of this.entries) this.index(candidate);
      this.markToolViewsDirty();
      return true;
    }
    // Ids at or below the head entry are either kept already or were dropped by it.
    if (this.ids.has(entry.id) || entry.id < this.head) return false;
    this.entries = [...this.entries, entry];
    this.index(entry);
    if (entry.model?.some((message) => message.role === "assistant")) this.markToolViewsDirty();
    return true;
  }

  private index(entry: EntryRecord): void {
    this.ids.add(entry.id);
    this.tip = Math.max(this.tip, entry.id);
    for (const message of entry.model ?? [])
      if (message.role === "assistant")
        for (const call of toolCallsOf(message))
          this.calls.set(call.id, { name: call.name, args: call.args });
  }

  /** Documents whose view reads committed tool calls (`pi.live`) are projected again. */
  private markToolViewsDirty(): void {
    for (const kind of this.committed.keys()) this.dirty.add(kind);
  }

  has(entryId: number): boolean {
    return this.ids.has(entryId);
  }

  entryView(entry: EntryRecord): ConversationEntryView {
    let view = this.entryViews.get(entry.id);
    if (!view) {
      view = projectEntry(entry, this.renderers, this);
      this.entryViews.set(entry.id, view);
    }
    return view;
  }

  /** Active entries after `entryId`, in order. Only valid while `entryId >= head`. */
  entriesAfter(entryId: number): ConversationEntryView[] {
    let start = this.entries.length;
    while (start > 0 && (this.entries[start - 1]?.id ?? 0) > entryId) start -= 1;
    return this.entries.slice(start).map((entry) => this.entryView(entry));
  }

  /** Current client documents. Values are immutable and shared by every subscriber. */
  clientDocs(): ReadonlyMap<string, JsonObject> {
    for (const kind of this.dirty) {
      const spec = CONVERSATION_CLIENT_DOCS.find((candidate) => candidate.kind === kind);
      const value = this.committed.get(kind);
      if (spec && value) this.projected.set(kind, spec.project(value, this));
    }
    this.dirty.clear();
    return this.projected;
  }

  call(name: string, args: unknown): ConversationToolCallView {
    if (typeof args !== "object" || args === null)
      return renderToolCall(this.renderers, name, args);
    const cached = this.callViews.get(args);
    if (cached?.name === name) return cached.view;
    const view = renderToolCall(this.renderers, name, args);
    this.callViews.set(args, { name, view });
    return view;
  }

  committedCall(callId: string): { name: string; args: unknown } | undefined {
    return this.calls.get(callId);
  }

  join(subscriber: ConversationStreamSubscription): void {
    this.subscribers.add(subscriber);
  }

  leave(subscriber: ConversationStreamSubscription): void {
    this.subscribers.delete(subscriber);
    if (this.subscribers.size === 0) this.close();
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    for (const detach of this.detach.splice(0)) detach();
    for (const subscriber of [...this.subscribers]) subscriber.dispose();
    const rooms = ROOMS.get(this.harness);
    if (rooms?.get(this.conversationId)?.room === this) rooms.delete(this.conversationId);
  }
}

/** One socket's view of a room: what it has sent, and when it may send again. */
export class ConversationStreamSubscription {
  private sentHead = 0;
  private sentTip = 0;
  private sentDocs = new Map<string, JsonObject>();
  private timer: ReturnType<typeof setTimeout> | undefined;
  private lastSentAt = 0;
  private disposed = false;

  constructor(
    private readonly room: ConversationRoom,
    private readonly send: SendFrame,
  ) {}

  /**
   * First frame. A cursor that is a known active entry at or after the head resumes
   * with an `update` of the entries after it and every document whole; anything else
   * (no cursor, unknown id, or a head that moved past it) is a `snapshot`.
   */
  start(afterEntryId: number | undefined): void {
    if (
      afterEntryId !== undefined &&
      afterEntryId >= this.room.head &&
      this.room.has(afterEntryId)
    ) {
      this.sentHead = this.room.head;
      this.sentTip = afterEntryId;
      this.flush(true);
    } else this.sendSnapshot();
  }

  notify(): void {
    if (this.disposed || this.timer) return;
    const wait = Math.max(0, this.lastSentAt + CONVERSATION_FRAME_INTERVAL_MS - Date.now());
    // Even a zero wait yields, so commits published in the same turn share a frame.
    this.timer = setTimeout(() => {
      this.timer = undefined;
      if (!this.disposed) this.flush(false);
    }, wait);
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    clearTimeout(this.timer);
    this.timer = undefined;
    this.room.leave(this);
  }

  private emit(frame: ConversationStreamServerMessage): void {
    this.lastSentAt = Date.now();
    this.send(frame);
  }

  private sendSnapshot(): void {
    const docs = this.room.clientDocs();
    this.sentHead = this.room.head;
    this.sentTip = this.room.tip;
    this.sentDocs = new Map(docs);
    this.emit({
      type: "snapshot",
      conversationId: this.room.conversationId,
      head: this.room.head,
      hasOlder: this.room.hasOlder,
      entries: this.room.entries.map((entry) => this.room.entryView(entry)),
      docs: Object.fromEntries(docs),
    });
  }

  /** `resume` sends every document whole (or `null`), since the client's copies are unknown. */
  private flush(resume: boolean): void {
    if (this.room.head !== this.sentHead) {
      this.sendSnapshot();
      return;
    }
    const entries = this.room.entriesAfter(this.sentTip);
    const current = this.room.clientDocs();
    const docs: Record<string, ConversationDocOp[] | null> = {};
    for (const { kind } of CONVERSATION_CLIENT_DOCS) {
      const previous = this.sentDocs.get(kind);
      const next = current.get(kind);
      if (next === undefined) {
        if (previous !== undefined || resume) docs[kind] = null;
        this.sentDocs.delete(kind);
        continue;
      }
      if (next === previous) continue;
      const ops = previous === undefined ? [["r", next] as const] : diffRevisions(previous, next);
      this.sentDocs.set(kind, next);
      if (ops.length) docs[kind] = ops;
    }
    this.sentTip = this.room.tip;
    const hasDocs = Object.keys(docs).length > 0;
    if (!resume && !entries.length && !hasDocs) return;
    this.emit({
      type: "update",
      conversationId: this.room.conversationId,
      ...(entries.length || resume ? { entries } : {}),
      ...(hasDocs ? { docs } : {}),
    });
  }
}

const ROOMS = new WeakMap<
  Harness,
  Map<ConversationId, { opening: Promise<ConversationRoom>; room?: ConversationRoom }>
>();

async function roomFor(
  harness: Harness,
  conversationId: ConversationId,
  renderers: MobileRendererRegistry,
): Promise<ConversationRoom> {
  let rooms = ROOMS.get(harness);
  if (!rooms) {
    rooms = new Map();
    ROOMS.set(harness, rooms);
  }
  const existing = rooms.get(conversationId);
  if (existing) return existing.opening;
  const slot: { opening: Promise<ConversationRoom>; room?: ConversationRoom } = {
    opening: ConversationRoom.open(harness, conversationId, renderers),
  };
  rooms.set(conversationId, slot);
  try {
    slot.room = await slot.opening;
    return slot.room;
  } catch (error) {
    if (rooms.get(conversationId) === slot) rooms.delete(conversationId);
    throw error;
  }
}

/**
 * Attach one socket to a conversation. Sends the first frame before resolving;
 * `dispose()` ends it. Rooms are shared per conversation and close with their
 * last subscriber.
 */
export async function attachConversationStream(options: {
  harness: Harness;
  conversationId: ConversationId;
  renderers: MobileRendererRegistry;
  afterEntryId?: number;
  send: SendFrame;
}): Promise<ConversationStreamSubscription> {
  for (;;) {
    const room = await roomFor(options.harness, options.conversationId, options.renderers);
    // The last subscriber may have closed this room while we waited for it.
    if (room.closed) continue;
    const subscription = new ConversationStreamSubscription(room, options.send);
    room.join(subscription);
    subscription.start(options.afterEntryId);
    return subscription;
  }
}
