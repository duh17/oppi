import { isDeepStrictEqual } from "node:util";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import {
  InboxDoc,
  LiveDoc,
  defineDocFamily,
  type Conversation,
  type ConversationId,
  type EntryId,
  type GenerationCheckpoint,
  type Harness,
  type InboxState,
  type InputEntry,
  type SettledSubmissionRecord,
  type Submission,
  type Tx,
  type UserInput,
} from "@earendil-works/pi-durable";
import { resolveDurableInputCards } from "./durable-input-cards.js";
import { recordInputFailure } from "./durable-failure-cards.js";
import type { SessionHost } from "./durable-harness.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import type { ChatAttachmentRef, MessageQueueItem } from "./types.js";

const log = createLogger({ base: { component: "durable-agent-controller" } });

// Submission records omit content after queued input withdrawal. Keep its
// fingerprint durable too, so a later replay cannot silently change that input.
const RequestContent = defineDocFamily<{ content: string; display?: string }, null>({
  kind: "oppi.request-content",
  version: 1,
  family: true,
  scope: "conversation",
  history: "latest",
  fork: "initial",
  initial: () => ({ content: "" }),
});

/** What the queue shows for an input instead of its model content. */
export interface RequestDisplay {
  message: string;
  attachments: ChatAttachmentRef[];
  createdAt: number;
  kind?: string;
}

/** The display a prompt stored for `requestId`, if it gave one. */
export async function readRequestDisplay(
  harness: Harness,
  conversationId: ConversationId,
  requestId: string,
): Promise<RequestDisplay | undefined> {
  const metadata = await harness.snapshot(
    RequestContent,
    conversationId,
    requestId,
    BACKGROUND_CONTEXT,
  );
  return metadata?.display ? (JSON.parse(metadata.display) as RequestDisplay) : undefined;
}

export interface PromptOptions {
  /** Durable identity of this input: the same id with the same content is the same input. */
  requestId: string;
  /** Omitted: a busy conversation rejects the input. */
  whenBusy?: "steer" | "followUp";
  /** Place the input as this entry instead of `pi.user` (an agent message). */
  entry?: InputEntry;
  /** Queue display when it differs from the content (an expanded Skill, attachments). */
  display?: { message: string; attachments: ChatAttachmentRef[] };
  /** Once aborted, admission is refused. An admitted input's failure card does not depend on it. */
  signal?: AbortSignal;
  /** Runs inside admission, after a new (not duplicate) input is submitted. */
  onAccepted?: () => void;
}

export interface PromptResult {
  submission: Submission;
  duplicate: boolean;
  /** The settled record; an unanswered input's failure card is written before this resolves. */
  settled: Promise<SettledSubmissionRecord>;
}

export interface QueuedInputs {
  steering: MessageQueueItem[];
  followUp: MessageQueueItem[];
}

type QueuedInput = Exclude<InboxState["items"][number], { mode: "write" }>;

/**
 * Input and run control of one conversation. `SessionHost.controller` keeps one per open
 * conversation, so every caller (the session socket's `DurableBackend` facade, `session_send`)
 * shares one admission chain and one request-id dedupe.
 */
export class DurableAgentController {
  private admissions: Promise<void> = Promise.resolve();
  private closed = false;

  constructor(
    private readonly harness: Harness,
    private readonly conversation: Conversation,
    private readonly host: SessionHost,
  ) {}

  /** The host dropped this controller; settlements after this leave cards to attach reconcile. */
  close(): void {
    this.closed = true;
  }

  async prompt(content: UserInput, options: PromptOptions): Promise<PromptResult> {
    this.host.assertSchedulingReady();
    const { requestId } = options;
    // Shared lifecycle permits allow concurrent prompts. Serialize only durable
    // admission so two copies of one request cannot both append a local user row.
    const admission = this.admissions.then(async () => {
      options.signal?.throwIfAborted();
      this.host.assertSchedulingReady();
      const existing = await this.conversation.commit(async (tx) => {
        const record = await tx.submissionByRequest(this.conversation.id, requestId);
        const queued =
          record && record.entry === undefined
            ? (await tx.doc(InboxDoc, this.conversation.id)).items.find(
                (item) => item.id === record.id,
              )
            : undefined;
        const stored =
          record?.entry !== undefined
            ? (await tx.entry(record.entry))?.model?.find((item) => item.role === "user")?.content
            : queued && queued.mode !== "write"
              ? queued.content
              : undefined;
        const fingerprint = await tx.doc(RequestContent, this.conversation.id, requestId, null);
        if (!record) {
          fingerprint.content = JSON.stringify(content);
          if (options.display)
            fingerprint.display = JSON.stringify({
              ...options.display,
              createdAt: Date.now(),
              kind: options.whenBusy,
            } satisfies RequestDisplay);
          return undefined;
        }
        if (
          stored !== undefined
            ? !isDeepStrictEqual(content, stored)
            : fingerprint.content !== JSON.stringify(content)
        )
          throw new Error(
            "clientTurnId conflict: the stored durable submission has different content",
          );
        return record;
      }, BACKGROUND_CONTEXT);
      const submission = await this.conversation.submit(
        {
          type: "input",
          content,
          requestId,
          whenBusy: options.whenBusy ?? "reject",
          ...(options.entry ? { entry: options.entry } : {}),
        },
        BACKGROUND_CONTEXT,
      );
      if (!existing) options.onAccepted?.();
      return { submission, duplicate: existing !== undefined };
    });
    this.admissions = admission.then(
      () => undefined,
      () => undefined,
    );
    const { submission, duplicate } = await admission;
    // Admission, not the whole generation, is the prompt. Abort must not wait
    // behind a stream, and a duplicate can find its settled submission.
    const settled = submission.wait(BACKGROUND_CONTEXT).then(async (record) => {
      if (
        this.closed ||
        record.status !== "unanswered" ||
        record.reason === "aborted" ||
        record.type !== "input" ||
        record.reason === "withdrawn"
      )
        return record;
      try {
        await recordInputFailure(this.conversation, record);
      } catch (error) {
        log.warn("durable_failure.input_card_failed", {
          submissionId: record.id,
          error: safeErrorMessage(error),
        });
      }
      return record;
    });
    // Callers that do not watch the settlement (session_send) must not leave a rejection unhandled.
    settled.catch(() => undefined);
    return { submission, duplicate, settled };
  }

  steer(content: UserInput, options: Omit<PromptOptions, "whenBusy">): Promise<PromptResult> {
    return this.prompt(content, { ...options, whenBusy: "steer" });
  }

  followUp(content: UserInput, options: Omit<PromptOptions, "whenBusy">): Promise<PromptResult> {
    return this.prompt(content, { ...options, whenBusy: "followUp" });
  }

  /**
   * Queued user inputs, without generated input cards. `stamp` sees the raw inbox inside the
   * commit that read it; its result comes back as `version`.
   */
  async queue(
    stamp: (inbox: InboxState["items"]) => number,
  ): Promise<QueuedInputs & { version: number }> {
    await this.admissions;
    const { internal, items, version } = await this.conversation.commit(async (tx) => {
      // Cards and inbox membership must share a mutation line: a generated
      // report admitted after the card read must not flash as user input.
      const { submissions: internal } = await resolveDurableInputCards(tx, this.conversation.id);
      const inbox = await tx.doc(InboxDoc, this.conversation.id);
      const items = JSON.parse(JSON.stringify(inbox.items)) as InboxState["items"];
      // Stamp while this snapshot is the newest inbox: a placement that commits during the
      // display reads below gets a later version, so clients drop this snapshot, not its update.
      return { internal, items, version: stamp(items) };
    }, BACKGROUND_CONTEXT);
    const queue: QueuedInputs & { version: number } = { version, steering: [], followUp: [] };
    for (const item of items) {
      if (item.mode === "write" || internal.has(item.id)) continue;
      queue[item.mode === "steer" ? "steering" : "followUp"].push(await this.queueItem(item));
    }
    return queue;
  }

  /** Withdraw one queued user input, or all of them; returns what was withdrawn. */
  async cancelQueued(itemId?: string): Promise<QueuedInputs> {
    const withdrawn: QueuedInputs = { steering: [], followUp: [] };
    // Snapshot identities only. Each commit checks current inbox membership and
    // current internal-card receipts; placement in between is a successful no-op.
    const inbox = await this.harness.snapshot(InboxDoc, this.conversation.id, BACKGROUND_CONTEXT);
    const ids = (inbox?.items ?? [])
      .filter(
        (item) => item.mode !== "write" && (itemId === undefined || String(item.id) === itemId),
      )
      .map((item) => item.id);
    for (const id of ids) {
      const item = await this.conversation.commit(async (tx) => {
        const inbox = await tx.doc(InboxDoc, this.conversation.id);
        const { submissions } = await resolveDurableInputCards(tx, this.conversation.id);
        const index = inbox.items.findIndex(
          (item) => item.id === id && item.mode !== "write" && !submissions.has(item.id),
        );
        const item = inbox.items[index];
        if (!item || item.mode === "write") return undefined;
        // Mirrors pi-durable inbox.js withdrawQueuedInputs/removeInboxItem.
        // Membership on this mutation line means queued in this conversation;
        // placement and settlement remove it atomically. Never re-admit inputs.
        const snapshot = JSON.parse(JSON.stringify(item)) as typeof item;
        tx.settleSubmission(item.id, { status: "unanswered", reason: "aborted" });
        inbox.items.splice(index, 1);
        return snapshot;
      }, BACKGROUND_CONTEXT);
      if (item)
        withdrawn[item.mode === "steer" ? "steering" : "followUp"].push(await this.queueItem(item));
    }
    return withdrawn;
  }

  private async queueItem(item: QueuedInput): Promise<MessageQueueItem> {
    const receipt = await this.harness.submission(item.id, BACKGROUND_CONTEXT);
    const record = await receipt?.status(BACKGROUND_CONTEXT);
    const display = record?.requestId
      ? await readRequestDisplay(this.harness, this.conversation.id, record.requestId)
      : undefined;
    const text =
      typeof item.content === "string"
        ? item.content
        : item.content.map((block) => (block.type === "text" ? block.text : "")).join("");
    return {
      id: String(item.id),
      message: display?.message ?? text,
      ...(display?.attachments?.length ? { attachments: display.attachments } : {}),
      createdAt: display?.createdAt ?? 0,
    };
  }

  abort(): Promise<void> {
    return this.host.abortConversation(this.conversation.id);
  }

  /**
   * Cancel a pending retry backoff and nothing else. The failed attempt's error is already
   * in the transcript; aborting only the generation task ends the run as aborted and leaves
   * queued inputs in the inbox, as classic does. Outside a backoff this does nothing, as classic.
   * Queued inputs also stay unstarted afterwards: pi-durable places the inbox only at a boundary or
   * on the next submission, after an aborted run as after a failed one.
   *
   * The generation's retry phase clears `pi.live.generation.retry` and moves the same task on to
   * `prepare` in one commit, then runs the next attempt under the same task id. A read followed by
   * `harness.abortTask` therefore lets a backoff that ends in between abort the new attempt, which
   * classic (it only aborts the sleep) never does. The check and the mark must be one commit, and
   * `abortTask` cannot do that: it marks whatever state the task has when its own commit runs.
   * pi-durable's public `Tx` reads the task and `pi.live` but has no way to write the mark, so this
   * calls `setTask`, the call `abortTask` itself makes, on the commit's own transaction. The
   * scheduler's commit listener signals the run invocation and starts the abort handler for the
   * mark from any commit. `waitForTask` then returns once the abort handler has ended the run.
   */
  async abortRetry(): Promise<void> {
    this.host.assertSchedulingReady();
    const id = this.conversation.id;
    const marked = await this.conversation.commit(async (tx) => {
      const live = await tx.doc(LiveDoc, id);
      if (live.generation?.retry === undefined || live.run === undefined) return undefined;
      const task = await tx.task(live.run.taskId);
      if (task === undefined || task.abortRequested) return undefined;
      const state = task.state;
      if (state.status !== "running" && state.status !== "pending") return undefined;
      if ((state.checkpoint as GenerationCheckpoint).phase !== "retry") return undefined;
      const { setTask } = tx as Tx & { setTask?: (record: typeof task) => void };
      if (typeof setTask !== "function") {
        throw new Error("pi-durable no longer lets a commit mark a task abort-requested");
      }
      setTask.call(tx, { ...task, abortRequested: true });
      return task.id;
    }, BACKGROUND_CONTEXT);
    if (marked !== undefined) await this.harness.waitForTask(marked, BACKGROUND_CONTEXT);
  }

  /** Compact now; resolves with the summary once the compaction entry is placed. */
  async compact(instructions?: string): Promise<{ summary: string; firstKeptEntryId: string }> {
    this.host.assertSchedulingReady();
    const id = await this.conversation.compact(instructions, BACKGROUND_CONTEXT);
    const task = await this.harness.waitForTask(id, BACKGROUND_CONTEXT);
    const outcome = task.state.outcome;
    if (outcome.status !== "completed" || outcome.result.submissionId === undefined)
      throw new Error("Server durable compaction did not produce a summary");
    const submission = await this.harness.submission(
      outcome.result.submissionId,
      BACKGROUND_CONTEXT,
    );
    const placed = await submission?.wait(BACKGROUND_CONTEXT);
    if (placed?.status !== "done") throw new Error("Server durable compaction was not placed");
    const entry = await this.conversation.commit(
      (tx) => tx.entry(placed.entry),
      BACKGROUND_CONTEXT,
    );
    const message = entry?.model?.[0];
    if (!message || message.role !== "user")
      throw new Error("Server durable compaction summary is unavailable");
    const summary =
      typeof message.content === "string"
        ? message.content
        : message.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("");
    return { summary, firstKeptEntryId: String(entry?.head) };
  }

  /** Resolves once the conversation has no run and no queued input. */
  waitForPrompt(): Promise<void> {
    return this.conversation.waitForIdle(BACKGROUND_CONTEXT);
  }

  /** A new ownerless conversation branched at `entryId`; see `SessionHost.forkConversation`. */
  fork(entryId: EntryId): Promise<ConversationId | undefined> {
    return this.host.forkConversation(this.conversation.id, entryId);
  }
}
