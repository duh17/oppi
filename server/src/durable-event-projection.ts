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
    // A restart resends the request, rather than continuing this partial. Replaying
    // the old partial here would create a visible stub even if its later end is hidden.
    const events = snapshotEvents(
      recovering ? { ...snapshot, generation: undefined } : snapshot,
      this.adapter,
    );
    if (snapshot.generation?.retry) {
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
    for (const event of events) {
      if (event.type === "snapshot") {
        out.push(...this.snapshot(event, false));
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
        const active = this.compacting.get(event.taskId);
        if (!active) continue;
        const task = await this.harness.getTask(event.taskId as TaskId<CompactionResult>, context);
        const outcome = task && "outcome" in task.state ? task.state.outcome : undefined;
        const failure = events.find(
          (item) => item.type === "task_failed" && item.taskId === event.taskId,
        );
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
        out.push(
          this.pi({
            type: "compaction_end",
            reason: active.reason,
            aborted: outcome?.status === "aborted",
            errorMessage,
            willRetry: false,
          }),
        );
        this.compacting.delete(event.taskId);
        continue;
      }
      if (event.type === "message_start" && hidden.has(event.message)) continue;
      if (event.type === "message_end") {
        const message = event.entry.model?.[0];
        if (hidden.has(message)) {
          this.adapter.partial = undefined;
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
      out.push(...adaptDurableEvent(event, this.adapter));
    }
    for (const [taskId, active] of this.compacting) {
      if (!active.result) continue;
      let entryId = active.result.entryId;
      if (active.result.submissionId !== undefined) {
        const submission = await this.harness.submission(active.result.submissionId, context);
        const status = await submission?.status(context);
        entryId = status?.entry;
        if (status?.status === "unanswered") {
          out.push(
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
      const placedId = entryId;
      const entry =
        this.entries.find((item) => item.id === placedId) ??
        (await this.harness.commit((tx) => tx.entry(placedId), context));
      if (!entry || !CompactionEntry.is(entry)) continue;
      out.push(
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
    return out;
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
