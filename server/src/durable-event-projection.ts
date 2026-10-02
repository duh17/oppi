import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import { estimateContextTokens } from "@earendil-works/pi-ai/utils/estimate";
import {
  CompactionEntry,
  type AgentEvent,
  type CompactionResult,
  type ConversationRetryPolicy,
  type EntryRecord,
  type Harness,
  type SnapshotEvent,
  type TaskId,
} from "@earendil-works/pi-durable";
import { adaptDurableEvent, createAdapterState, snapshotEvents } from "./durable-event-adapter.js";

type Compacting = {
  reason: string;
  tokensBefore: number;
  result?: CompactionResult;
};

/** Hide only interrupted attempts whose SAME generation retries, never a user Stop.
 * A later assistant entry attributed to the same generation proves a retry even
 * if the user subsequently Stops it: hide earlier stubs, keep the latest Stop.
 * Otherwise a live non-abort-marked generation or completed/model-failed receipt
 * proves continuation; aborted/faulted/orphaned/unknown tasks stay visible.
 * Task attribution, not adjacency/text matching, also handles repeated crashes.
 * Shared by live projection and the durable history reader; storage stays untouched.
 */
export async function isRecoveredPartial(
  entry: EntryRecord,
  harness: Harness,
  entries: readonly EntryRecord[],
): Promise<boolean> {
  const message = entry.model?.[0];
  if (message?.role !== "assistant" || message.stopReason !== "aborted" || !entry.byTaskId)
    return false;
  if (
    entries.some(
      (later) =>
        later.id > entry.id &&
        later.byTaskId === entry.byTaskId &&
        later.model?.[0]?.role === "assistant",
    )
  )
    return true;
  const task = await harness.getTask(entry.byTaskId, context);
  if (!task || task.kind !== "pi.generation" || task.abortRequested) return false;
  return task.state.status !== "terminal" && task.state.status !== "completing"
    ? true
    : task.state.outcome.status === "completed" || task.state.outcome.status === "failed";
}

export function compactionSummary(entry: EntryRecord): string {
  const message = entry.model?.[0];
  if (message?.role !== "user") return "";
  const text =
    typeof message.content === "string"
      ? message.content
      : message.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("");
  const wrapped = text.match(/<summary>\n?([\s\S]*?)\n?<\/summary>/);
  return (wrapped?.[1] ?? text).trim();
}

/** One serialized watch consumer; never waits for progress inside the watch.
 * Manual/background summary writes can be placed in a later commit, so successful
 * compaction ends are held until the receipt's entry/submission identifies the summary.
 */
export class DurableEventProjection {
  private readonly adapter = createAdapterState();
  private entries: EntryRecord[] = [];
  private readonly compacting = new Map<TaskId, Compacting>();
  readonly recoveredEntryIds = new Set<number>();
  private retry?: { attempt: number; taskId?: TaskId; error: string };
  private snapshotSeen = false;
  private runInputs?: readonly number[];

  constructor(
    private readonly harness: Harness,
    private readonly retryPolicy: () => Partial<ConversationRetryPolicy>,
  ) {}

  snapshot(snapshot: SnapshotEvent, recovering: boolean): AgentSessionEvent[] {
    this.entries = [...snapshot.entries];
    for (const entry of this.entries) {
      const message = entry.model?.[0];
      if (
        message?.role === "assistant" &&
        message.stopReason === "aborted" &&
        entry.byTaskId &&
        this.entries.some(
          (later) =>
            later.id > entry.id &&
            later.byTaskId === entry.byTaskId &&
            later.model?.[0]?.role === "assistant",
        )
      )
        this.recoveredEntryIds.add(entry.id);
    }
    const run = snapshot.run;
    const sameRun =
      this.snapshotSeen &&
      run !== undefined &&
      this.runInputs?.length === run.inputs.length &&
      this.runInputs.every((input, index) => input === run.inputs[index]);
    const previous = this.adapter.partial;
    const message = snapshot.generation?.message;
    const samePartial =
      sameRun &&
      previous !== undefined &&
      message !== undefined &&
      previous.timestamp === message.timestamp;
    // Startup recovery resends the request, so never replay its old partial. A
    // backlog snapshot of the same request only contributes missing suffix deltas;
    // restarting its bubble would duplicate the text already projected live.
    const events = snapshotEvents(
      {
        ...snapshot,
        ...(sameRun ? { run: undefined } : {}),
        ...(recovering || samePartial ? { generation: undefined } : {}),
      },
      this.adapter,
    );
    if (!recovering && samePartial && message) {
      this.adapter.partial = previous;
      events.push(
        ...adaptDurableEvent(
          { type: "message_update", usage: message.usage, changes: [{ type: "message", message }] },
          this.adapter,
        ),
      );
    }
    this.snapshotSeen = true;
    this.runInputs = snapshot.run?.inputs;
    if (
      snapshot.generation?.retry &&
      (!sameRun || this.retry?.attempt !== snapshot.generation.attempt)
    ) {
      this.retry = { attempt: snapshot.generation.attempt, error: snapshot.generation.retry.error };
      events.push(
        this.pi({
          type: "auto_retry_start",
          attempt: this.retry.attempt,
          maxAttempts: this.retryPolicy().maxRetries ?? 3,
          delayMs: Math.max(0, snapshot.generation.retry.at - Date.now()),
          errorMessage: this.retry.error,
        }),
      );
    }
    for (const status of snapshot.compactions) {
      if (this.compacting.has(status.taskId)) continue;
      this.compacting.set(status.taskId, { reason: status.reason, tokensBefore: this.estimate() });
      events.push(this.pi({ type: "compaction_start", reason: status.reason }));
    }
    return events;
  }

  async batch(events: readonly AgentEvent[]): Promise<AgentSessionEvent[]> {
    const out: AgentSessionEvent[] = [];
    // Capture remaining delay and context before any async receipt lookup can lag.
    const now = Date.now();
    for (const event of events) {
      if (event.type === "message_end" || event.type === "entry_appended") {
        if (!this.entries.some((entry) => entry.id === event.entry.id))
          this.entries.push(event.entry);
      }
    }
    for (const event of events) {
      if (event.type === "compaction_start")
        this.compacting.set(event.taskId, { reason: event.reason, tokensBefore: this.estimate() });
    }
    const hidden = new Set<unknown>();
    for (const event of events) {
      if (event.type !== "message_end") continue;
      if (await isRecoveredPartial(event.entry, this.harness, this.entries)) {
        hidden.add(event.entry.model?.[0]);
        this.recoveredEntryIds.add(event.entry.id);
      }
      const message = event.entry.model?.[0];
      // A summary is compaction chrome, not another user turn.
      if (CompactionEntry.is(event.entry)) hidden.add(message);
      // Overflow compaction is admitted in the SAME commit as the failed response.
      // Don't suppress an overflow when no cut exists or recovery already failed.
      if (
        message?.role === "assistant" &&
        message.stopReason === "error" &&
        events.some((item) => item.type === "compaction_start" && item.reason === "overflow")
      )
        hidden.add(message);
    }
    const ends = await this.compactionEnds(events);
    for (const event of events) {
      if (event.type === "snapshot") {
        // A snapshot can include an already-placed summary and a newer run.
        // Finish that hold before rebinding the newer run's live projection.
        out.push(...(ends.get(event) ?? []), ...this.snapshot(event, false));
        continue;
      }
      if (event.type === "auto_retry_start") {
        const failed = events.find(
          (item) => item.type === "message_end" && item.entry.model?.[0]?.role === "assistant",
        );
        this.retry = {
          attempt: event.attempt,
          error: event.errorMessage,
          taskId: failed?.type === "message_end" ? failed.entry.byTaskId : this.retry?.taskId,
        };
        out.push(
          this.pi({
            type: "auto_retry_start",
            attempt: event.attempt,
            maxAttempts: this.retryPolicy().maxRetries ?? 3,
            delayMs: Math.max(0, event.at - now),
            errorMessage: event.errorMessage,
          }),
        );
        continue;
      }
      if (event.type === "auto_retry_end") continue; // Backoff ended, NOT the retry loop.
      if (event.type === "compaction_end") {
        out.push(...(ends.get(event) ?? []));
        continue;
      }
      if (event.type === "message_start" && hidden.has(event.message)) continue;
      if (event.type === "message_end") {
        const message = event.entry.model?.[0];
        if (hidden.has(message)) {
          this.adapter.partial = undefined;
          out.push(...(ends.get(event) ?? []));
          continue;
        }
        if (
          this.retry &&
          message?.role === "assistant" &&
          (!this.retry.taskId || this.retry.taskId === event.entry.byTaskId) &&
          !events.some((item) => item.type === "auto_retry_start")
        ) {
          const success = ["stop", "length", "toolUse"].includes(message.stopReason);
          out.push(
            this.pi({
              type: "auto_retry_end",
              success,
              attempt: this.retry.attempt,
              ...(success ? {} : { finalError: message.errorMessage ?? this.retry.error }),
            }),
          );
          this.retry = undefined;
        }
      }
      if (event.type === "run_end" && this.retry) {
        out.push(
          this.pi({
            type: "auto_retry_end",
            success: false,
            attempt: this.retry.attempt,
            finalError: this.retry.error,
          }),
        );
        this.retry = undefined;
      }
      if (event.type === "run_start") this.runInputs = event.inputs;
      if (event.type === "run_end") this.runInputs = undefined;
      out.push(...adaptDurableEvent(event, this.adapter), ...(ends.get(event) ?? []));
    }
    return out;
  }

  private async compactionEnds(
    events: readonly AgentEvent[],
  ): Promise<Map<AgentEvent, AgentSessionEvent[]>> {
    const ends = new Map<AgentEvent, AgentSessionEvent[]>();
    const append = (event: AgentEvent, end: AgentSessionEvent): void => {
      ends.set(event, [...(ends.get(event) ?? []), end]);
    };
    // Receipts are immutable once the task ends. Resolve them before iterating
    // entries: blocking compaction appends its summary BEFORE compaction_end in
    // the same commit, and a held summary can be followed by a new run in its batch.
    const receipts = events.flatMap<{ event: AgentEvent; taskId: TaskId }>((event) => {
      if (event.type === "compaction_end") return [{ event, taskId: event.taskId }];
      if (event.type !== "snapshot") return [];
      // Backlog replacement discards the terminal commit too. Absence from live
      // compactions must reconcile every start we emitted, even without a receipt.
      return [...this.compacting.keys()]
        .filter((taskId) => !event.compactions.some((status) => status.taskId === taskId))
        .map((taskId) => ({ event, taskId }));
    });
    for (const { event, taskId } of receipts) {
      const active = this.compacting.get(taskId);
      if (!active) continue;
      const task = await this.harness.getTask(taskId as TaskId<CompactionResult>, context);
      const outcome = task && "outcome" in task.state ? task.state.outcome : undefined;
      if (!outcome) continue;
      const failure = events.find((item) => item.type === "task_failed" && item.taskId === taskId);
      if (outcome?.status === "completed") {
        active.result = outcome.result;
        if (outcome.result.entryId !== undefined || outcome.result.submissionId !== undefined)
          continue;
      }
      const errorMessage =
        failure?.type === "task_failed"
          ? failure.message
          : outcome?.status === "failed" || outcome?.status === "faulted"
            ? outcome.error.message
            : outcome?.status === "orphaned"
              ? outcome.reason
              : undefined;
      append(
        event,
        this.pi({
          type: "compaction_end",
          reason: active.reason,
          aborted: outcome?.status === "aborted",
          errorMessage,
          willRetry: false,
        }),
      );
      this.compacting.delete(taskId);
    }
    // Only placement-relevant publications can advance a queued write. Never
    // poll a submission on the serialized consumer for each streamed partial.
    const changed = events.find(
      (event) =>
        event.type === "message_end" ||
        event.type === "entry_appended" ||
        event.type === "submission" ||
        event.type === "inbox_update" ||
        event.type === "snapshot",
    );
    if (!changed) return ends;
    for (const [taskId, active] of this.compacting) {
      if (!active.result) continue;
      let entryId = active.result.entryId;
      const published = events.find(
        (event) => event.type === "submission" && event.record.id === active.result?.submissionId,
      );
      if (active.result.submissionId !== undefined) {
        const status =
          published?.type === "submission"
            ? published.record
            : await (
                await this.harness.submission(active.result.submissionId, context)
              )?.status(context);
        entryId = status?.entry;
        if (status?.status === "unanswered") {
          append(
            published ?? changed,
            this.pi({
              type: "compaction_end",
              reason: active.reason,
              aborted: true,
              willRetry: false,
            }),
          );
          this.compacting.delete(taskId);
          continue;
        }
      }
      if (entryId === undefined) continue;
      const placement = events.find(
        (event) =>
          ((event.type === "message_end" || event.type === "entry_appended") &&
            event.entry.id === entryId) ||
          (event.type === "snapshot" && event.entries.some((entry) => entry.id === entryId)),
      );
      const entry =
        placement?.type === "message_end" || placement?.type === "entry_appended"
          ? placement.entry
          : placement?.type === "snapshot"
            ? placement.entries.find((entry) => entry.id === entryId)
            : this.entries.find((entry) => entry.id === entryId);
      // A receipt read can be ahead of this watch. Don't fetch a future entry and
      // finish early: its placement publication (or replacement snapshot) owns order.
      if (!entry || !CompactionEntry.is(entry)) continue;
      const anchor =
        placement ??
        events.find((event) => event.type === "compaction_end" && event.taskId === taskId) ??
        published ??
        changed;
      append(
        anchor,
        this.pi({
          type: "compaction_end",
          reason: active.reason,
          aborted: false,
          // Only successful generation-owned overflow compaction retries the request.
          willRetry: active.reason === "overflow",
          result: {
            summary: compactionSummary(entry),
            firstKeptEntryId: String(entry.head),
            tokensBefore: active.tokensBefore,
          },
        }),
      );
      this.compacting.delete(taskId);
    }
    return ends;
  }

  private estimate(): number {
    // Public pi-ai estimator: latest applicable non-error assistant usage plus
    // trailing message estimates; otherwise ~4 chars/token (images ~1200 tokens).
    // Restrict to the newest compaction/reset head, excluding aborted/error attempts.
    const head = [...this.entries].reverse().find((entry) => entry.head !== undefined);
    const headId = head?.head ?? Number.NEGATIVE_INFINITY;
    const entries = head
      ? [
          head,
          ...this.entries.filter(
            (entry) => entry.id >= headId && entry.id !== head.id && entry.head === undefined,
          ),
        ]
      : this.entries;
    return estimateContextTokens(
      entries
        .flatMap((entry) => entry.model ?? [])
        .filter(
          (message) =>
            message.role !== "assistant" ||
            !["aborted", "error"].includes((message as AssistantMessage).stopReason),
        ),
    ).tokens;
  }

  private pi(event: object): AgentSessionEvent {
    return event as AgentSessionEvent;
  }
}
