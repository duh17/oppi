/**
 * Classic Pi session events for one durable conversation, derived from its state.
 *
 * The session socket's classic consumers (the Mac app, which does not attach the conversation
 * stream; `SessionEventProcessor`; Live Voice; the trace and telemetry) still read Pi
 * `AgentSessionEvent`s. Durable has no event API: everything they carried is state in the
 * conversation view (`pi.live`, `pi.inbox`, entries), so each view value is diffed against the
 * previous one and the difference is told as events, in the order the coding agent tells them.
 *
 * The view watch is the one ordered source for entries and `pi.live`, so an entry and the
 * live state its commit cleared always arrive together; it sees deferred progress commits at
 * once, before pi-durable stores them. Commit publications add only what no view holds: task
 * faults and nested call results. Submission records (which input was placed, which failed)
 * are read when an input leaves `pi.inbox` or a run ends.
 */
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import type { AssistantMessage, AssistantMessageEvent, Message } from "@earendil-works/pi-ai";
import { estimateContextTokens } from "@earendil-works/pi-ai/utils/estimate";
import {
  CompactionEntry,
  NestedCallDoc,
  UserEntry,
  type CommitPublication,
  type CompactionResult,
  type Conversation,
  type ConversationRetryPolicy,
  type ConversationView,
  type ConversationWatch,
  type EntryId,
  type EntryRecord,
  type Harness,
  type InboxState,
  type JsonObject,
  type LiveState,
  type NestedToolExecutionResult,
  type NestedToolSlot,
  type SubmissionId,
  type SubmissionRecord,
  type TaskId,
  type ToolSlot,
} from "@earendil-works/pi-durable";
import {
  AGENT_MESSAGE_ENTRY_KIND,
  agentMessageOrigin,
} from "../extensions/durable/sessions/agent-message.js";
import { compactionSummary, isRecoveredPartial } from "./durable-history.js";
import { readDurableInputCards } from "./durable-input-cards.js";
import { clientToolResult } from "./durable-tool-result-content.js";

type UnansweredInput = Extract<SubmissionRecord, { type: "input"; status: "unanswered" }>;
type PlacedInput = Extract<SubmissionRecord, { type: "input"; status: "placed" | "done" }>;
type Slot = ToolSlot | NestedToolSlot;

/** A task that faulted or was orphaned: its card and live error. */
export type DurableTaskFailure = { taskId: TaskId; kind: string; message: string };

/** What one view value (or one batch of task faults) told, in order. */
export type ClassicFrame = {
  /** Pi events, in the coding agent's order. */
  events: AgentSessionEvent[];
  /** Entries this value added, in id order, shown or not. */
  appended: EntryRecord[];
  /** Queued inputs this value placed. */
  placed: PlacedInput[];
  /** Inputs this value settled without an answer: an ended run's, or a queued one's. */
  unanswered: UnansweredInput[];
  inboxChanged: boolean;
  runStarted: boolean;
  runEnded: boolean;
  /**
   * A run that failed (`model_error`, `no_model`) with inputs queued behind it: its
   * `agent_settled` is held until they start (`settle`).
   */
  continuation?: SubmissionId;
  taskFailures: DurableTaskFailure[];
};

/** The unanswered reasons of a failed run: pi-durable keeps the inputs queued behind it. */
const FAILED_RUN_REASONS: ReadonlySet<string> = new Set(["model_error", "no_model"]);

const NESTED_CALL_KIND = NestedCallDoc.definition.kind;

type Compacting = { reason: string; tokensBefore: number; result?: CompactionResult };

function liveOf(view: ConversationView): LiveState {
  return (view.docs["pi.live"] as LiveState | undefined) ?? {};
}

function inboxOf(view: ConversationView): InboxState["items"] {
  return (view.docs["pi.inbox"] as InboxState | undefined)?.items ?? [];
}

function pi(event: object): AgentSessionEvent {
  return event as AgentSessionEvent;
}

function emptyFrame(): ClassicFrame {
  return {
    events: [],
    appended: [],
    placed: [],
    unanswered: [],
    inboxChanged: false,
    runStarted: false,
    runEnded: false,
    taskFailures: [],
  };
}

/**
 * Newest assistant written after the latest user input: `pi.user` or an agent message.
 * Compaction summaries and reset handoffs are user-role but not a new turn.
 * An assistant older than that user entry belongs to a finished turn.
 */
export function newestAssistantOfActiveRun(
  entries: readonly EntryRecord[],
): AssistantMessage | undefined {
  let lastUserId = -1;
  let newest: { id: number; message: AssistantMessage } | undefined;
  for (const entry of entries) {
    const message = entry.model?.[0];
    if ((UserEntry.is(entry) || entry.kind === AGENT_MESSAGE_ENTRY_KIND) && entry.id > lastUserId)
      lastUserId = entry.id;
    if (message?.role === "assistant" && (!newest || entry.id > newest.id))
      newest = { id: entry.id, message };
  }
  if (!newest || newest.id < lastUserId) return undefined;
  return newest.message;
}

/** Prefix growth stays a suffix delta. A rewrite carries the whole current text and `replace`. */
function contentDelta(
  previous: string,
  next: string,
): { delta: string; replace?: true } | undefined {
  if (next === previous) return undefined;
  if (next.startsWith(previous)) return { delta: next.slice(previous.length) };
  return { delta: next, replace: true };
}

/**
 * How the streamed answer changed from `prev` to `next`, block by block: a start for each new
 * block, the grown text as a delta, and a tool call whose arguments changed. Built from the
 * values, not from watch operations, so a folded or replaced value reads the same.
 */
export function messageUpdates(
  prev: AssistantMessage | undefined,
  next: AssistantMessage,
): AssistantMessageEvent[] {
  const events: AssistantMessageEvent[] = [];
  for (const [contentIndex, block] of next.content.entries()) {
    const old = prev?.content[contentIndex];
    if (block.type === "text" || block.type === "thinking") {
      const kind = block.type;
      const text = block.type === "text" ? block.text : block.thinking;
      const oldText =
        old?.type === "text" && kind === "text"
          ? old.text
          : old?.type === "thinking" && kind === "thinking"
            ? old.thinking
            : "";
      if (old?.type !== kind)
        events.push({
          type: `${kind}_start`,
          contentIndex,
          partial: next,
        } as AssistantMessageEvent);
      const projected = contentDelta(oldText, text);
      if (projected)
        events.push({
          type: `${kind}_delta`,
          contentIndex,
          delta: projected.delta,
          partial: next,
          ...(projected.replace ? { replace: true } : {}),
        } as AssistantMessageEvent);
    } else if (block.type === "toolCall") {
      if (old?.type !== "toolCall")
        events.push({ type: "toolcall_start", contentIndex, partial: next });
      else if (old !== block)
        events.push({ type: "toolcall_delta", contentIndex, delta: "", partial: next });
    }
  }
  return events;
}

/** What a nested call gave its script, as the text a tool row shows. */
function nestedResultText(result: NestedToolExecutionResult): string {
  const value = result.structuredOutput;
  if (value !== undefined) return typeof value === "string" ? value : JSON.stringify(value);
  return result.diagnostics
    .filter((diagnostic) => diagnostic.severity === "error")
    .map((diagnostic) => diagnostic.message)
    .join("\n");
}

function dummyAssistant(): AssistantMessage {
  return {
    role: "assistant",
    content: [],
    api: "anthropic-messages",
    provider: "faux",
    model: "faux-1",
    usage: {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
    stopReason: "stop",
    timestamp: Date.now(),
  };
}

function isNested(slot: Slot): slot is NestedToolSlot {
  return "parentCallId" in slot;
}

/** Slots of one value by identity: a model-issued call by call id, a nested one by task id. */
function slotsOf(live: LiveState): Map<string, Slot> {
  const slots = new Map<string, Slot>();
  for (const slot of live.tools ?? []) slots.set(`call:${slot.callId}`, slot);
  for (const slot of live.nestedTools ?? []) slots.set(`task:${slot.taskId}`, slot);
  return slots;
}

function parentOf(slot: Slot): { parentToolCallId?: string } {
  return isNested(slot) ? { parentToolCallId: slot.parentCallId } : {};
}

/**
 * One serialized consumer of a conversation's view watch. `frame` diffs each value against the
 * last; it never waits for progress inside the watch, so changes that land meanwhile arrive
 * folded into the next value.
 */
export class DurableClassicEvents {
  inputCards: Awaited<ReturnType<typeof readDurableInputCards>> = {
    entries: new Map(),
    submissions: new Set(),
  };
  /** The last value told; the acquisition value before `start`. */
  private current: ConversationView;
  /** Largest entry id told. */
  private tip: number;
  /** The streamed answer as told so far. */
  private shown?: AssistantMessage;
  /** Arguments of each call told as started, for its updates and end. */
  private readonly toolArgs = new Map<string, JsonObject>();
  private readonly compacting = new Map<TaskId, Compacting>();
  private retry?: { attempt: number; error: string; taskId?: TaskId };
  /** Nested call results from commit publications, by the nested call's task. */
  private readonly nestedResults = new Map<TaskId, NestedToolExecutionResult>();
  private settleHeld = false;
  private chain: Promise<void> = Promise.resolve();
  private unsubscribe?: () => void;
  private stopped = false;

  private constructor(
    private readonly harness: Harness,
    private readonly conversation: Conversation,
    private readonly watch: ConversationWatch,
    private readonly retryPolicy: () => Partial<ConversationRetryPolicy>,
  ) {
    this.current = watch.value;
    this.tip = Math.max(0, ...watch.value.entries.map((entry) => entry.id));
  }

  static async open(
    harness: Harness,
    conversation: Conversation,
    retryPolicy: () => Partial<ConversationRetryPolicy>,
  ): Promise<DurableClassicEvents> {
    const watch = await conversation.watch(context);
    const events = new DurableClassicEvents(harness, conversation, watch, retryPolicy);
    try {
      await events.refreshInputCards();
    } catch (error) {
      await watch.stop();
      throw error;
    }
    return events;
  }

  /** The conversation view as last told: its documents are what the events said. */
  get view(): ConversationView {
    return this.current;
  }

  private async refreshInputCards(): Promise<void> {
    this.inputCards = await readDurableInputCards(this.harness, [
      this.conversation.id,
      ...this.current.entries.map((entry) => entry.conversationId),
    ]);
  }

  /**
   * Re-bind a live run without inventing another input. `recovering`: startup recovery resends
   * the request, so its old partial is not shown.
   */
  snapshot(recovering: boolean): AgentSessionEvent[] {
    const live = liveOf(this.current);
    const events: AgentSessionEvent[] = [];
    if (live.run) events.push(pi({ type: "agent_start" }));
    const message = live.generation?.message as AssistantMessage | undefined;
    if (message && !recovering) events.push(...this.streamed(message));
    for (const slot of slotsOf(live).values()) {
      if (slot.status !== "running") continue;
      events.push(this.toolStart(slot, this.current.entries), ...this.toolUpdate(slot));
    }
    const retry = live.generation?.retry;
    if (retry && live.generation) {
      this.retry = { attempt: live.generation.attempt, error: retry.error };
      events.push(this.retryStart(live.generation.attempt, retry, Date.now()));
    }
    for (const status of live.compactions ?? []) {
      this.compacting.set(status.taskId, {
        reason: status.reason,
        tokensBefore: this.estimate(this.current.entries),
      });
      events.push(pi({ type: "compaction_start", reason: status.reason }));
    }
    return events;
  }

  /**
   * Deliver every later value, and task faults from commits, to `listener`, one frame at a
   * time. A listener that throws ends the watch, as the event stream did.
   */
  start(listener: (frame: ClassicFrame) => Promise<void>): void {
    this.unsubscribe = this.harness.subscribeCommits((publication) =>
      this.publish(publication, listener),
    );
    this.watch.start((value) => this.enqueue(async () => listener(await this.frame(value))));
  }

  async stop(): Promise<void> {
    this.stopped = true;
    this.unsubscribe?.();
    this.unsubscribe = undefined;
    await this.watch.stop();
    await this.chain;
  }

  /** The held `agent_settled`, when no run followed the failed one after all. */
  settle(): AgentSessionEvent[] {
    if (!this.settleHeld) return [];
    this.settleHeld = false;
    return [pi({ type: "agent_settled" })];
  }

  private enqueue(work: () => Promise<void>): Promise<void> {
    const next = this.chain.then(() => (this.stopped ? undefined : work()));
    this.chain = next.catch(() => {});
    return next;
  }

  /** Commit listener: synchronous, never throws, never calls Session APIs. */
  private publish(
    publication: CommitPublication,
    listener: (frame: ClassicFrame) => Promise<void>,
  ): void {
    const failures: DurableTaskFailure[] = [];
    for (const change of publication.changes) {
      if (change.type === "document" && change.record.kind === NESTED_CALL_KIND && change.value) {
        const state = change.value as { taskId?: TaskId; result?: NestedToolExecutionResult };
        if (state.taskId !== undefined && state.result !== undefined)
          this.nestedResults.set(state.taskId, state.result);
      }
      if (change.type !== "task" || change.value.conversationId !== this.conversation.id) continue;
      const task = change.value;
      if (task.state.status !== "terminal") continue;
      if (task.kind === "pi.generation" || task.kind === "pi.compaction") continue;
      const outcome = task.state.outcome;
      if (outcome.status === "faulted" || outcome.status === "orphaned")
        failures.push({
          taskId: task.id,
          kind: task.kind,
          message: outcome.status === "faulted" ? outcome.error.message : outcome.reason,
        });
    }
    if (failures.length)
      void this.enqueue(() => listener({ ...emptyFrame(), taskFailures: failures })).catch(
        () => {},
      );
  }

  /** The events between the last value told and `next`. */
  async frame(next: ConversationView): Promise<ClassicFrame> {
    const frame = emptyFrame();
    const prev = this.current;
    const was = liveOf(prev);
    const now = liveOf(next);
    const out = frame.events;
    const appended = next.entries
      .filter((entry) => entry.id > this.tip)
      .sort((left, right) => left.id - right.id);
    frame.appended = appended;
    frame.inboxChanged = prev.docs["pi.inbox"] !== next.docs["pi.inbox"];
    this.current = next;
    this.tip = Math.max(this.tip, ...appended.map((entry) => entry.id));
    if (appended.length || frame.inboxChanged) await this.refreshInputCards();

    // Reads first, so the events below are built from one consistent picture.
    const startedCompactions = (now.compactions ?? []).filter(
      (status) => !(was.compactions ?? []).some((old) => old.taskId === status.taskId),
    );
    for (const status of startedCompactions)
      this.compacting.set(status.taskId, {
        reason: status.reason,
        tokensBefore: this.estimate(next.entries),
      });
    const hidden = new Set<number>();
    for (const entry of appended) {
      const message = entry.model?.[0];
      if (
        CompactionEntry.is(entry) ||
        this.inputCards.entries.has(entry.id) ||
        (await isRecoveredPartial(entry, this.harness, next.entries)) ||
        // Overflow compaction is admitted in the same commit as the failed response it retries.
        (message?.role === "assistant" &&
          message.stopReason === "error" &&
          startedCompactions.some((status) => status.reason === "overflow"))
      )
        hidden.add(entry.id);
    }
    const compactionEnds = await this.compactionEnds(was, now, appended, frame.inboxChanged);
    const nestedEnds = await this.nestedEnds(was, now);
    const runChanged = now.run?.inputs[0] !== was.run?.inputs[0];
    const ended = runChanged ? was.run : undefined;
    const runEnded = ended !== undefined;
    const runStarted = now.run !== undefined && runChanged;
    frame.runEnded = runEnded;
    frame.runStarted = runStarted;
    const settled = await this.settledInputs(prev, next, ended?.inputs ?? []);
    frame.placed = settled.placed;
    frame.unanswered = settled.unanswered;

    // Progress: tool starts, the streamed answer, tool updates, retry backoff.
    const before = slotsOf(was);
    const after = slotsOf(now);
    for (const [key, slot] of after) {
      if (slot.status !== "running" || before.get(key)?.status === "running") continue;
      out.push(this.toolStart(slot, next.entries), ...this.toolUpdate(slot));
    }
    const message = now.generation?.message as AssistantMessage | undefined;
    if (message && message !== this.shown) {
      if (this.shown?.timestamp === message.timestamp)
        out.push(...this.updates(this.shown, message));
      else out.push(...this.streamed(message));
    }
    for (const [key, slot] of after) {
      const previous = before.get(key);
      if (slot.status !== "running" || previous?.status !== "running") continue;
      if (slot.output !== previous.output || slot.details !== previous.details)
        out.push(...this.toolUpdate(slot));
    }
    const generation = now.generation;
    const retry = generation?.retry;
    const retryStarted =
      generation !== undefined &&
      retry !== undefined &&
      (was.generation?.retry === undefined || was.generation.attempt !== generation.attempt);
    if (generation && retry && retryStarted) {
      const failed = appended.find((entry) => entry.model?.[0]?.role === "assistant");
      this.retry = {
        attempt: generation.attempt,
        error: retry.error,
        taskId: failed?.byTaskId ?? now.run?.taskId,
      };
      out.push(this.retryStart(generation.attempt, retry, Date.now()));
    }

    // Tools that end, entries in append order (a tool's end right before its result), and the
    // compaction a summary entry finishes.
    const ends: Array<{ slot: Slot; entry?: EntryRecord }> = [];
    for (const [key, previous] of before) {
      if (previous.status === "done" || isNested(previous)) continue;
      const slot = after.get(key) as ToolSlot | undefined;
      if (slot?.status === "done")
        ends.push({ slot, entry: appended.find((entry) => entry.id === slot.entry) });
      else if (slot === undefined)
        ends.push({ slot: previous, entry: resultOf(appended, previous.callId) });
    }
    for (const [key, slot] of after)
      if (!isNested(slot) && slot.status === "done" && !before.has(key))
        ends.push({ slot, entry: appended.find((entry) => entry.id === slot.entry) });
    for (const end of nestedEnds) out.push(end);
    for (const entry of appended) {
      for (const end of ends) if (end.entry === entry) out.push(this.toolEnd(end.slot, entry));
      out.push(...(compactionEnds.placed.get(entry.id) ?? []));
      const message = entry.model?.[0];
      if (!message) continue;
      if (hidden.has(entry.id)) {
        if (message.role === "assistant") this.shown = undefined;
        continue;
      }
      // A streamed answer already started with its first partial; one that landed whole (no
      // partial was ever shown) streams its content now, as Pi's start is empty then deltas.
      if (message.role !== "assistant") out.push(pi({ type: "message_start", message }));
      else if (!this.shown) out.push(...this.streamed(message));
      if (message.role === "assistant") this.shown = undefined;
      const agentMessage = agentMessageOrigin(entry.kind, entry.data);
      out.push(
        pi({
          type: "message_end",
          message,
          entryId: String(entry.id),
          ...(agentMessage ? { agentMessage } : {}),
        }),
      );
      if (
        this.retry &&
        !retryStarted &&
        message.role === "assistant" &&
        (!this.retry.taskId || this.retry.taskId === entry.byTaskId)
      ) {
        const success = ["stop", "length", "toolUse"].includes(message.stopReason);
        out.push(
          pi({
            type: "auto_retry_end",
            success,
            attempt: this.retry.attempt,
            ...(success ? {} : { finalError: message.errorMessage ?? this.retry.error }),
          }),
        );
        this.retry = undefined;
      }
    }
    for (const end of ends) if (end.entry === undefined) out.push(this.toolEnd(end.slot));
    out.push(...compactionEnds.unplaced);

    // Turn and run ends, then what began.
    if (was.run !== undefined && was.run.taskId !== now.run?.taskId)
      out.push(pi({ type: "turn_end", message: this.shown ?? dummyAssistant(), toolResults: [] }));
    if (ended) {
      if (this.retry) {
        out.push(
          pi({
            type: "auto_retry_end",
            success: false,
            attempt: this.retry.attempt,
            finalError: this.retry.error,
          }),
        );
        this.retry = undefined;
      }
      const assistant = newestAssistantOfActiveRun(next.entries);
      // Durable's run end names no messages. The ending run's assistant goes last, as in Pi's
      // list: SessionEventProcessor records turn_error from it, and Live Voice says a failed or
      // stopped run failed.
      out.push(pi({ type: "agent_end", messages: assistant ? [assistant] : [], willRetry: false }));
      this.shown = undefined;
      this.toolArgs.clear();
      this.nestedResults.clear();
      // Classic settles once no run follows: hold it when the next run starts here, or when a
      // failed run left inputs queued, which `DurableAgentController.continueAfterFailedRun`
      // starts once its failure card is written.
      const failed = frame.unanswered.find(
        (input) => FAILED_RUN_REASONS.has(input.reason) && ended.inputs.includes(input.id),
      );
      if (runStarted) this.settleHeld = false;
      else if (failed && inboxOf(next).some((item) => item.mode !== "write")) {
        this.settleHeld = true;
        frame.continuation = failed.id;
      } else out.push(pi({ type: "agent_settled" }));
    }
    for (const status of startedCompactions)
      out.push(pi({ type: "compaction_start", reason: status.reason }));
    if (runStarted) {
      this.settleHeld = false;
      out.push(pi({ type: "agent_start" }));
    }
    if (now.run !== undefined && now.run.taskId !== was.run?.taskId)
      out.push(pi({ type: "turn_start" }));
    return frame;
  }

  /** A first partial: an empty start, then its content as deltas, as Pi streams it. */
  private streamed(message: AssistantMessage): AgentSessionEvent[] {
    this.shown = message;
    return [pi({ type: "message_start", message }), ...this.updates(undefined, message)];
  }

  private updates(prev: AssistantMessage | undefined, next: AssistantMessage): AgentSessionEvent[] {
    this.shown = next;
    return messageUpdates(prev, next).map((assistantMessageEvent) =>
      pi({ type: "message_update", message: next, assistantMessageEvent }),
    );
  }

  private retryStart(
    attempt: number,
    retry: { at: number; error: string },
    now: number,
  ): AgentSessionEvent {
    return pi({
      type: "auto_retry_start",
      attempt,
      maxAttempts: this.retryPolicy().maxRetries ?? 3,
      delayMs: Math.max(0, retry.at - now),
      errorMessage: retry.error,
    });
  }

  private toolStart(slot: Slot, entries: readonly EntryRecord[]): AgentSessionEvent {
    // A nested slot carries what the call runs with; a model-issued call's are in its answer.
    const args = isNested(slot) ? slot.arguments : (callArguments(entries, slot.callId) ?? {});
    this.toolArgs.set(slot.callId, args);
    return pi({
      type: "tool_execution_start",
      toolCallId: slot.callId,
      toolName: slot.name,
      args,
      ...parentOf(slot),
    });
  }

  private toolUpdate(slot: Slot): AgentSessionEvent[] {
    const output = slot.output ?? "";
    if (!output && slot.details === undefined) return [];
    return [
      pi({
        type: "tool_execution_update",
        toolCallId: slot.callId,
        toolName: slot.name,
        args: this.toolArgs.get(slot.callId) ?? {},
        partialResult: {
          content: output ? [{ type: "text", text: output }] : [],
          ...(slot.details !== undefined && slot.details !== null ? { details: slot.details } : {}),
        },
        ...parentOf(slot),
      }),
    ];
  }

  private toolEnd(
    slot: Slot,
    entry?: EntryRecord,
    nested?: NestedToolExecutionResult,
  ): AgentSessionEvent {
    const args = this.toolArgs.get(slot.callId) ?? {};
    this.toolArgs.delete(slot.callId);
    const base = { type: "tool_execution_end", toolCallId: slot.callId, toolName: slot.name, args };
    const message = entry?.model?.[0];
    if (message?.role === "toolResult") {
      // The stored message ends with the diagnostics block pi-durable adds for the model.
      const shown = clientToolResult(message, entry?.data);
      return pi({
        ...base,
        result: { content: shown.content, details: message.details },
        isError: message.isError === true,
        ...parentOf(slot),
      });
    }
    // A nested call writes no transcript entry; its result is what the script got.
    if (nested)
      return pi({
        ...base,
        result: {
          content: [{ type: "text", text: nestedResultText(nested) }],
          details: nested.details ?? {},
        },
        isError: nested.isError,
        ...parentOf(slot),
      });
    const summary = isNested(slot) ? slot.summary : undefined;
    return pi({
      ...base,
      result: { content: [{ type: "text", text: summary?.error ?? "" }], details: {} },
      isError: summary?.isError ?? true,
      ...parentOf(slot),
    });
  }

  /**
   * Nested calls that end in this value, children before the calls that made them (the list
   * holds parents first). Their result is in the caller's `NestedCallDoc`, which retires with the
   * caller, so a publication's copy is used first.
   */
  private async nestedEnds(was: LiveState, now: LiveState): Promise<AgentSessionEvent[]> {
    const current = new Map((now.nestedTools ?? []).map((slot) => [slot.taskId, slot]));
    const previous = new Map((was.nestedTools ?? []).map((slot) => [slot.taskId, slot]));
    const ending: NestedToolSlot[] = [];
    for (const old of [...previous.values()].reverse()) {
      if (old.status === "done") continue;
      const slot = current.get(old.taskId);
      if (slot === undefined || slot.status === "done") ending.push(slot ?? old);
    }
    for (const slot of [...current.values()].reverse())
      if (slot.status === "done" && !previous.has(slot.taskId)) ending.push(slot);
    const events: AgentSessionEvent[] = [];
    for (const slot of ending) {
      let result = this.nestedResults.get(slot.taskId);
      if (result === undefined) {
        const key = slot.callId.slice(slot.parentCallId.length + 1);
        const state = await this.harness.snapshot(NestedCallDoc, slot.parentTaskId, key, context);
        result = (state?.result as NestedToolExecutionResult | undefined) ?? undefined;
      }
      this.nestedResults.delete(slot.taskId);
      events.push(this.toolEnd(slot, undefined, result));
    }
    return events;
  }

  /**
   * Inputs that left `pi.inbox` or ended with the run, read from their records: placed ones
   * start a queue item, unanswered ones fail.
   */
  private async settledInputs(
    prev: ConversationView,
    next: ConversationView,
    runInputs: readonly SubmissionId[],
  ): Promise<{ placed: PlacedInput[]; unanswered: UnansweredInput[] }> {
    const queued = new Set(inboxOf(next).map((item) => item.id));
    const left = inboxOf(prev)
      .filter((item) => item.mode !== "write" && !queued.has(item.id))
      .map((item) => item.id);
    const placed: PlacedInput[] = [];
    const unanswered: UnansweredInput[] = [];
    for (const id of new Set([...left, ...runInputs])) {
      const record = await (await this.harness.submission(id, context))?.status(context);
      if (record?.type !== "input") continue;
      if (record.status === "unanswered") unanswered.push(record);
      else if (left.includes(id) && (record.status === "placed" || record.status === "done"))
        placed.push(record);
    }
    return { placed, unanswered };
  }

  /**
   * Compactions whose status left `pi.live`, and held successes whose summary this value
   * placed. A success waits for its summary entry, which a manual compaction places later
   * through a write submission; its end goes right where the summary lands.
   */
  private async compactionEnds(
    was: LiveState,
    now: LiveState,
    appended: readonly EntryRecord[],
    inboxChanged: boolean,
  ): Promise<{ placed: Map<number, AgentSessionEvent[]>; unplaced: AgentSessionEvent[] }> {
    const placed = new Map<number, AgentSessionEvent[]>();
    const unplaced: AgentSessionEvent[] = [];
    const end = (active: Compacting, fields: object): AgentSessionEvent =>
      pi({
        type: "compaction_end",
        reason: active.reason,
        aborted: false,
        willRetry: false,
        ...fields,
      });
    for (const status of was.compactions ?? []) {
      const taskId = status.taskId;
      if ((now.compactions ?? []).some((other) => other.taskId === taskId)) continue;
      const active = this.compacting.get(taskId);
      if (!active) continue;
      const failure = now.compactionFailure;
      if (failure?.taskId === taskId) {
        unplaced.push(end(active, { errorMessage: failure.error }));
        this.compacting.delete(taskId);
        continue;
      }
      const task = await this.harness.getTask(taskId as TaskId<CompactionResult>, context);
      const outcome = task && "outcome" in task.state ? task.state.outcome : undefined;
      if (outcome?.status === "completed") {
        active.result = outcome.result;
        if (outcome.result.entryId !== undefined || outcome.result.submissionId !== undefined)
          continue;
      }
      unplaced.push(
        end(active, {
          aborted: outcome?.status === "aborted",
          errorMessage:
            outcome?.status === "failed" || outcome?.status === "faulted"
              ? outcome.error.message
              : outcome?.status === "orphaned"
                ? outcome.reason
                : undefined,
        }),
      );
      this.compacting.delete(taskId);
    }
    if (!appended.length && !inboxChanged) return { placed, unplaced };
    for (const [taskId, active] of this.compacting) {
      if (!active.result) continue;
      let entryId: EntryId | undefined = active.result.entryId;
      if (active.result.submissionId !== undefined) {
        const record = await (
          await this.harness.submission(active.result.submissionId, context)
        )?.status(context);
        if (record?.status === "unanswered") {
          unplaced.push(end(active, { aborted: true }));
          this.compacting.delete(taskId);
          continue;
        }
        entryId = record?.entry;
      }
      const entry = appended.find((candidate) => candidate.id === entryId);
      if (!entry || !CompactionEntry.is(entry)) continue;
      placed.set(entry.id, [
        ...(placed.get(entry.id) ?? []),
        end(active, {
          // Only a successful generation-owned overflow compaction retries the request.
          willRetry: active.reason === "overflow",
          result: {
            summary: compactionSummary(entry),
            firstKeptEntryId: String(entry.head),
            tokensBefore: active.tokensBefore,
          },
        }),
      ]);
      this.compacting.delete(taskId);
    }
    return { placed, unplaced };
  }

  /**
   * Public pi-ai estimator over the context from the newest head: the latest applicable
   * non-error assistant usage plus trailing message estimates.
   */
  private estimate(entries: readonly EntryRecord[]): number {
    const head = [...entries].reverse().find((entry) => entry.head !== undefined);
    const headId = head?.head ?? Number.NEGATIVE_INFINITY;
    const active = head
      ? [
          head,
          ...entries.filter(
            (entry) => entry.id >= headId && entry.id !== head.id && entry.head === undefined,
          ),
        ]
      : entries;
    return estimateContextTokens(
      active
        .flatMap((entry): readonly Message[] => entry.model ?? [])
        .filter(
          (message) =>
            message.role !== "assistant" || !["aborted", "error"].includes(message.stopReason),
        ),
    ).tokens;
  }
}

/** The tool result for `callId` among `entries`. */
function resultOf(entries: readonly EntryRecord[], callId: string): EntryRecord | undefined {
  return entries.find((entry) => {
    const message = entry.model?.[0];
    return message?.role === "toolResult" && message.toolCallId === callId;
  });
}

/** The arguments the model gave call `callId`, from the newest answer that made it. */
function callArguments(entries: readonly EntryRecord[], callId: string): JsonObject | undefined {
  for (const entry of [...entries].reverse()) {
    const message = entry.model?.[0];
    if (message?.role !== "assistant") continue;
    for (const block of message.content)
      if (block.type === "toolCall" && block.id === callId) return block.arguments as JsonObject;
  }
  return undefined;
}
