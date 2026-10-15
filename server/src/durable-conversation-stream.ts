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
 *
 * Entries carry the presentation trace history gives them: input cards and hidden
 * recovered partials. Both depend on state outside the entry (input-card receipts, task
 * records), so the room decides them in asynchronous passes with the trace's own helpers
 * and holds frames while a pass runs. A presentation that changes after an entry was
 * sent goes out again as an upsert of that entry.
 */
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { diffRevisions } from "@earendil-works/chord/delta";
import type {
  CommitPublication,
  Conversation,
  ConversationId,
  EntryId,
  EntryRecord,
  Harness,
  JsonObject,
} from "@earendil-works/pi-durable";
import { DurableInputCards } from "../extensions/durable/durable-ui.js";
import {
  CONVERSATION_CLIENT_DOCS,
  projectEntry,
  renderToolCall,
  toolCallsOf,
  type ToolPresenter,
} from "./durable-conversation-view.js";
import { isAbortedAttempt, isRecoveredPartial } from "./durable-history.js";
import { readDurableInputCards } from "./durable-input-cards.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import type { MobileRendererRegistry } from "./mobile-renderer.js";
import type {
  ConversationDocOp,
  ConversationEntryCard,
  ConversationEntryView,
  ConversationStreamServerMessage,
  ConversationToolCallView,
} from "./types.js";

const log = createLogger({ base: { component: "durable-conversation-stream" } });

/** Durable commits partials and tool output at most this often; faster frames gain nothing. */
export const CONVERSATION_FRAME_INTERVAL_MS = 100;

const CLIENT_DOC_KINDS = new Set(CONVERSATION_CLIENT_DOCS.map((spec) => spec.kind));
const INPUT_CARDS_KIND = DurableInputCards.definition.kind;

/** `older` pages: visible entries per request by default, and at most. */
export const CONVERSATION_OLDER_LIMIT = 100;
export const CONVERSATION_OLDER_MAX = 500;

type SendFrame = (frame: ConversationStreamServerMessage) => void;
type OlderFrame = Extract<ConversationStreamServerMessage, { type: "older" }>;

function isUserEntry(entry: EntryRecord): boolean {
  return entry.model?.[0]?.role === "user";
}

function sameCard(
  left: ConversationEntryCard | undefined,
  right: ConversationEntryCard | undefined,
): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

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
  /** Active aborted attempts by id: the entries `isRecoveredPartial` may hide. */
  private readonly attempts = new Map<number, EntryRecord>();
  /** Active extension-generated inputs, shown as their card. */
  private readonly inputCards = new Map<number, ConversationEntryCard>();
  /** Active entries the trace hides. */
  private readonly hidden = new Set<number>();
  /** Revision of each entry's latest presentation change. */
  private readonly revisions = new Map<number, number>();
  /** Increases with every presentation change. */
  revision = 0;
  /** Presentation passes queued or running. Frames wait until none is. */
  private passes = 0;
  private passChain: Promise<void> = Promise.resolve();
  /** Publications that arrive while the room loads; replayed over the loaded state. */
  private pending: CommitPublication[] | undefined = [];
  private readonly detach: Array<() => void> = [];
  /**
   * Settles when the room has loaded. Rejects when the load fails or the room closed
   * first (the Harness closed), so no waiter ever receives a closed room it must retry.
   */
  readonly ready: Promise<void>;

  /** Starts loading at once; callers await `ready`. */
  constructor(
    private readonly harness: Harness,
    readonly conversationId: ConversationId,
    private readonly renderers: MobileRendererRegistry,
  ) {
    // Subscribe before reading so no commit falls between the read and the listener.
    this.detach.push(harness.subscribeCommits((publication) => this.publish(publication)));
    this.detach.push(harness.subscribeClose(() => this.close()));
    this.ready = this.load().then(
      () => {
        if (this.closed)
          throw new Error(`Conversation stream ${conversationId} closed while it loaded`);
      },
      (error: unknown) => {
        this.close();
        throw error;
      },
    );
  }

  private async load(): Promise<void> {
    const conversation = await this.harness.conversation(this.conversationId, context);
    if (!conversation) throw new Error(`Durable conversation ${this.conversationId} is missing`);
    const state = await conversation.viewState(context);
    const view = state.value;
    state.dispose();
    // Installed whole, not through `addEntry`: the view lists the head marker first, then
    // the entries it keeps, whose ids are below the marker's and which `addEntry` drops.
    this.entries = [...view.entries];
    const marker = this.entries[0];
    if (marker?.head !== undefined) this.head = marker.id;
    for (const entry of this.entries) this.index(entry);
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
    await this.presentPass(this.entries.filter(isUserEntry), true);
    // Replaying commits the read already saw is idempotent: entries are keyed by id,
    // head moves re-select the same suffix, and each document ends at its newest value.
    const pending = this.pending ?? [];
    this.pending = undefined;
    for (const publication of pending) this.apply(publication);
    await this.settled();
  }

  /** A presentation pass is queued or running; frames wait for it. */
  get presenting(): boolean {
    return this.passes > 0;
  }

  /** Resolves when no presentation pass is queued or running. */
  async settled(): Promise<void> {
    while (this.passes > 0) await this.passChain;
  }

  /** Queue a presentation pass; subscribers flush when the last one ends. */
  private present(users: EntryRecord[], partials: boolean): void {
    this.passes += 1;
    this.passChain = this.passChain
      .then(() => this.presentPass(users, partials))
      .catch((error: unknown) => {
        // A Harness that closes mid-pass rejects its reads; the room closes with it.
        if (this.closed) return;
        log.error("conversation_stream.present_failed", {
          conversationId: this.conversationId,
          error: safeErrorMessage(error),
        });
      })
      .finally(() => {
        this.passes -= 1;
        if (this.passes === 0 && !this.closed && !this.pending)
          for (const subscriber of this.subscribers) subscriber.notify();
      });
  }

  /**
   * Decide input cards for `users` and hiding for every active attempt, with the helpers
   * trace history uses (`readDurableInputCards`, `isRecoveredPartial`).
   */
  private async presentPass(users: readonly EntryRecord[], partials: boolean): Promise<void> {
    const targets = users.filter((entry) => this.ids.has(entry.id));
    if (targets.length) {
      const cards = await readDurableInputCards(
        this.harness,
        targets.map((entry) => entry.conversationId),
      );
      for (const entry of targets)
        if (this.ids.has(entry.id))
          this.setInputCard(entry.id, cards.entries.get(entry.id as EntryId));
    }
    if (!partials) return;
    for (const entry of [...this.attempts.values()]) {
      const hidden = await isRecoveredPartial(entry, this.harness, this.entries);
      if (this.attempts.has(entry.id)) this.setHidden(entry.id, hidden);
    }
  }

  private setInputCard(id: number, card: ConversationEntryCard | undefined): void {
    if (sameCard(this.inputCards.get(id), card)) return;
    if (card) this.inputCards.set(id, card);
    else this.inputCards.delete(id);
    this.changed(id);
  }

  private setHidden(id: number, hidden: boolean): void {
    if (this.hidden.has(id) === hidden) return;
    if (hidden) this.hidden.add(id);
    else this.hidden.delete(id);
    this.changed(id);
  }

  private changed(id: number): void {
    this.entryViews.delete(id);
    this.revision += 1;
    this.revisions.set(id, this.revision);
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
    let cardsChanged = false;
    let attemptTaskChanged = false;
    const entries: EntryRecord[] = [];
    for (const change of publication.changes) {
      if (change.type === "entry") {
        if (change.value.conversationId === this.conversationId) entries.push(change.value);
        continue;
      }
      if (change.type === "task") {
        // A task's state decides whether its aborted attempts are hidden.
        const taskId = change.value.id;
        for (const attempt of this.attempts.values())
          if (attempt.byTaskId === taskId) attemptTaskChanged = true;
        continue;
      }
      if (
        change.type !== "document" ||
        change.conversationId !== this.conversationId ||
        change.record.key !== undefined
      )
        continue;
      if (change.record.kind === INPUT_CARDS_KIND) {
        cardsChanged = true;
        continue;
      }
      if (!CLIENT_DOC_KINDS.has(change.record.kind)) continue;
      if (change.value) this.setDoc(change.record.kind, change.value);
      else {
        this.committed.delete(change.record.kind);
        this.projected.delete(change.record.kind);
        this.dirty.delete(change.record.kind);
      }
      changed = true;
    }
    entries.sort((left, right) => left.id - right.id);
    const added = entries.filter((entry) => this.addEntry(entry));
    if (added.length || cardsChanged || attemptTaskChanged) {
      // Card metadata is published before its input, but a late one still applies to it.
      const users = cardsChanged ? this.entries.filter(isUserEntry) : added.filter(isUserEntry);
      const partials = this.attempts.size > 0 && (added.length > 0 || attemptTaskChanged);
      if (users.length || partials) this.present(users, partials);
    }
    return changed || added.length > 0;
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
      this.attempts.clear();
      for (const candidate of this.entries) this.index(candidate);
      for (const id of [...this.entryViews.keys()])
        if (!this.ids.has(id)) this.entryViews.delete(id);
      for (const id of [...this.inputCards.keys()])
        if (!this.ids.has(id)) this.inputCards.delete(id);
      for (const id of [...this.hidden]) if (!this.ids.has(id)) this.hidden.delete(id);
      for (const id of [...this.revisions.keys()]) if (!this.ids.has(id)) this.revisions.delete(id);
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
    if (isAbortedAttempt(entry)) this.attempts.set(entry.id, entry);
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
      view = projectEntry(entry, this.renderers, this, {
        inputCard: this.inputCards.get(entry.id),
        hidden: this.hidden.has(entry.id),
      });
      this.entryViews.set(entry.id, view);
    }
    return view;
  }

  /** Active entries a snapshot shows, in display order. */
  visibleEntries(): ConversationEntryView[] {
    return this.entries
      .filter((entry) => !this.hidden.has(entry.id))
      .map((entry) => this.entryView(entry));
  }

  /** Shown active entries after `entryId`, in order. Only valid while `entryId >= head`. */
  entriesAfter(entryId: number): ConversationEntryView[] {
    let start = this.entries.length;
    while (start > 0 && (this.entries[start - 1]?.id ?? 0) > entryId) start -= 1;
    return this.entries
      .slice(start)
      .filter((entry) => !this.hidden.has(entry.id))
      .map((entry) => this.entryView(entry));
  }

  /** Active entries up to `entryId` whose presentation changed after `revision`, by id. */
  changedSince(revision: number, entryId: number): ConversationEntryView[] {
    return this.restate(
      (entry) => entry.id <= entryId && (this.revisions.get(entry.id) ?? 0) > revision,
    );
  }

  /**
   * Active entries up to `entryId` whose presentation is not their content alone: aborted
   * attempts, shown or hidden, and input cards. A resumed client may hold either form.
   */
  presentedUpTo(entryId: number): ConversationEntryView[] {
    return this.restate(
      (entry) =>
        entry.id <= entryId && (this.attempts.has(entry.id) || this.inputCards.has(entry.id)),
    );
  }

  private restate(select: (entry: EntryRecord) => boolean): ConversationEntryView[] {
    return this.entries
      .filter(select)
      .sort((left, right) => left.id - right.id)
      .map((entry) => this.entryView(entry));
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
    if (rooms?.get(this.conversationId) === this) rooms.delete(this.conversationId);
  }
}

/** One socket's view of a room: what it has sent, and when it may send again. */
export class ConversationStreamSubscription {
  private sentHead = 0;
  private sentTip = 0;
  /** The room's presentation revision as of the last frame. */
  private sentRevision = 0;
  private sentDocs = new Map<string, JsonObject>();
  private timer: ReturnType<typeof setTimeout> | undefined;
  private lastSentAt = 0;
  private disposed = false;

  constructor(
    private readonly room: ConversationRoom,
    private readonly send: SendFrame,
  ) {}

  /** The newest entry id sent; a new subscription started after it resumes this socket. */
  get cursor(): number {
    return this.sentTip;
  }

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
    this.sentRevision = this.room.revision;
    this.sentDocs = new Map(docs);
    this.emit({
      type: "snapshot",
      conversationId: this.room.conversationId,
      head: this.room.head,
      hasOlder: this.room.hasOlder,
      entries: this.room.visibleEntries(),
      docs: Object.fromEntries(docs),
    });
  }

  /**
   * `resume` sends every document whole (or `null`), since the client's copies are unknown,
   * and restates every held entry whose presentation may differ from the client's copy.
   */
  private flush(resume: boolean): void {
    // The room notifies again when its presentation pass ends.
    if (this.room.presenting) return;
    if (this.room.head !== this.sentHead) {
      this.sendSnapshot();
      return;
    }
    const restated = resume
      ? this.room.presentedUpTo(this.sentTip)
      : this.room.changedSince(this.sentRevision, this.sentTip);
    const entries = [...restated, ...this.room.entriesAfter(this.sentTip)];
    this.sentRevision = this.room.revision;
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

/** Open rooms, loading or loaded. A room removes itself when it closes. */
const ROOMS = new WeakMap<Harness, Map<ConversationId, ConversationRoom>>();

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
  let room = rooms.get(conversationId);
  if (!room) {
    room = new ConversationRoom(harness, conversationId, renderers);
    rooms.set(conversationId, room);
  }
  await room.ready;
  return room;
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
    // The first frame shows decided presentation only.
    await room.settled();
    // The last subscriber may have left this loaded room while we waited for it. It removed
    // itself from ROOMS, so the retry opens a new room.
    if (room.closed) continue;
    if (room.presenting) continue;
    const subscription = new ConversationStreamSubscription(room, options.send);
    room.join(subscription);
    subscription.start(options.afterEntryId);
    return subscription;
  }
}

/** Entries after `afterId`, oldest first, through the first assistant entry. */
async function throughNextAssistant(
  conversation: Conversation,
  afterId: number,
): Promise<EntryRecord[]> {
  const entries: EntryRecord[] = [];
  let cursor;
  do {
    const page = await conversation.entries(
      { minEntryId: (afterId + 1) as EntryId, order: "ascending" },
      32,
      cursor,
      context,
    );
    for (const entry of page.items) {
      entries.push(entry);
      if (entry.model?.[0]?.role === "assistant") return entries;
    }
    cursor = page.next;
  } while (cursor !== undefined);
  return entries;
}

/**
 * The `older` page: up to `limit` shown entries before `beforeEntryId`, oldest first, with
 * the presentation the stream and trace history give them. Reads `conversation.entries()`
 * newest first, like the trace pages do.
 */
export async function readOlderConversationEntries(options: {
  harness: Harness;
  conversationId: ConversationId;
  renderers: MobileRendererRegistry;
  beforeEntryId: number;
  limit?: number;
}): Promise<OlderFrame> {
  const { harness, conversationId, renderers, beforeEntryId } = options;
  const limit = Math.min(
    Math.max(1, options.limit ?? CONVERSATION_OLDER_LIMIT),
    CONVERSATION_OLDER_MAX,
  );
  const conversation = await harness.conversation(conversationId, context);
  if (!conversation) throw new Error(`Durable conversation ${conversationId} is missing`);
  const scanned: EntryRecord[] = [];
  const shown: EntryRecord[] = [];
  // Recovery evidence past the page: a retry's answer is the next assistant entry, since a
  // conversation runs one generation at a time.
  let after: EntryRecord[] | undefined;
  let cursor;
  if (beforeEntryId > 1)
    do {
      const page = await conversation.entries(
        { maxEntryId: (beforeEntryId - 1) as EntryId },
        limit,
        cursor,
        context,
      );
      cursor = page.next;
      scanned.push(...page.items);
      for (const entry of page.items) {
        if (isAbortedAttempt(entry)) {
          after ??= await throughNextAssistant(conversation, beforeEntryId - 1);
          if (await isRecoveredPartial(entry, harness, [...scanned, ...after])) continue;
        }
        shown.push(entry);
      }
    } while (shown.length < limit && cursor !== undefined);
  const page = shown.slice(0, limit).reverse();
  const users = page.filter(isUserEntry);
  const cards = users.length
    ? (
        await readDurableInputCards(
          harness,
          users.map((entry) => entry.conversationId),
        )
      ).entries
    : new Map<EntryId, ConversationEntryCard>();
  const tools: ToolPresenter = {
    call: (name, args) => renderToolCall(renderers, name, args),
    committedCall: () => undefined,
  };
  return {
    type: "older",
    conversationId,
    entries: page.map((entry) =>
      projectEntry(entry, renderers, tools, { inputCard: cards.get(entry.id as EntryId) }),
    ),
    hasOlder: shown.length > limit || cursor !== undefined,
  };
}
