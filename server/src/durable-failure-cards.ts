import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import type { JsonValue } from "@earendil-works/chord";
import {
  defineDoc,
  LiveDoc,
  type Conversation,
  type ConversationId,
  type Cursor,
  type EntryRecord,
  type Harness,
  type InboxState,
  type RunFailure,
  type Storage,
  type TaskId,
  type TaskRecord,
  type Tx,
} from "@earendil-works/pi-durable";
import { DURABLE_FAILURE_REQUEST_ID_PREFIX } from "./durable-request-ids.js";

/** Display-only transcript row. Not a model message, and not `oppi-` (that prefix is hidden). */
export const DURABLE_FAILURE_ENTRY_KIND = "oppi.failure";

/**
 * Tasks with id <= `taskId` have been examined. `open` lists the non-terminal
 * ids in that prefix, so a later fault is rechecked without scanning history.
 * A fork starts empty: task ids are global, and the parent's open set is not this conversation's.
 */
export const FailureCardsDoc = defineDoc<{ taskId: number; open: number[] }>({
  kind: "oppi.failure-cards",
  version: 1,
  scope: "conversation",
  history: "latest",
  fork: "initial",
  initial: () => ({ taskId: 0, open: [] }),
  // Advances with the conversation's tasks for its lifetime; a base bounds its replay.
  checkpointWhen: (_value, _ops, { deltasSinceBase }) => deltasSinceBase >= 64,
});

/**
 * Run ends that are no failure: an explicit Stop, a continue that found nothing to answer, and
 * a host stop mid-request, which Oppi continues (`continuesAfter`). Withdrawn queued inputs
 * settle without a run, so they never reach `runFailure`.
 */
const QUIET_RUN_FAILURES: ReadonlySet<RunFailure["reason"]> = new Set([
  "aborted",
  "nothing_to_answer",
  "interrupted",
]);

/** The unanswered reasons of a failed run: pi-durable keeps the inputs queued behind it. */
const FAILED_RUN_REASONS: ReadonlySet<RunFailure["reason"]> = new Set(["model_error", "no_model"]);

/**
 * Whether Oppi continues after `failure`: a run a host stop cut off with no retry left
 * (`interrupted`) always, a failed one when inputs wait queued behind it.
 */
export function continuesAfter(failure: RunFailure, inbox: InboxState["items"]): boolean {
  if (failure.reason === "interrupted") return true;
  return FAILED_RUN_REASONS.has(failure.reason) && inbox.some((item) => item.mode !== "write");
}

const PAGE = 100;

/** One card per failed run, keyed by the task that ended it, so a retry writes nothing. */
function failureRunRequestId(id: TaskId): string {
  return `${DURABLE_FAILURE_REQUEST_ID_PREFIX}run:${id}`;
}

function failureTaskRequestId(id: TaskId): string {
  return `${DURABLE_FAILURE_REQUEST_ID_PREFIX}task:${id}`;
}

/**
 * History renders assistant text, thinking, and tool calls. It does not render
 * `errorMessage`, so a `stopReason: "error"` entry is not already the failure row.
 * Skip the card only when that same text is already visible, which would be a second row.
 */
async function assistantFailureAlreadyVisible(
  tx: Tx,
  conversationId: ConversationId,
  text: string,
): Promise<boolean> {
  const needle = text.trim();
  if (!needle) return false;
  let cursor: Cursor | undefined;
  do {
    const page = await tx.scanEntries({ conversationId }, 500, cursor);
    if (page.items.some((entry) => assistantText(entry).includes(needle))) return true;
    cursor = page.next;
  } while (cursor !== undefined);
  return false;
}

function assistantText(entry: EntryRecord): string {
  const message = entry.model?.[0];
  if (message?.role !== "assistant" || message.stopReason !== "error") return "";
  const content = message.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .flatMap((block) => (block.type === "text" && block.text ? [block.text] : []))
    .join("\n");
}

type FailureCard = { title: string; body: string; status?: string; at: number };

/** What a failed run's card says; undefined for a quiet end (Stop, nothing to answer). */
export function runFailureText(failure: RunFailure): string | undefined {
  if (QUIET_RUN_FAILURES.has(failure.reason)) return undefined;
  return failure.detail?.trim() ? failure.detail : failure.reason;
}

async function appendFailureCard(
  tx: Tx,
  conversationId: ConversationId,
  requestId: string,
  card: FailureCard,
): Promise<void> {
  const entry = await tx.appendEntry(conversationId, {
    kind: DURABLE_FAILURE_ENTRY_KIND,
    data: {
      card: {
        title: card.title,
        body: card.body,
        accent: "error",
        at: card.at,
        ...(card.status ? { status: card.status } : {}),
      },
    },
  });
  await tx.createSubmission({
    conversationId,
    requestId,
    type: "write",
    status: "done",
    entry: entry.id,
  });
}

async function writeFailureCard(
  tx: Tx,
  conversationId: ConversationId,
  requestId: string,
  card: FailureCard,
): Promise<void> {
  if (await tx.submissionByRequest(conversationId, requestId)) return;
  await appendFailureCard(tx, conversationId, requestId, card);
}

/**
 * Queue the card commit before returning. Callers must not await anything first:
 * a prompt sent in the same turn has to land behind this commit, not ahead of it.
 * The request-id check and the visible-text check both run inside the commit.
 */
export function recordRunFailure(conversation: Conversation, failure: RunFailure): Promise<void> {
  const body = runFailureText(failure);
  if (body === undefined) return Promise.resolve();
  const requestId = failureRunRequestId(failure.taskId);
  const card = { title: "Run failed", body, status: failure.reason, at: Date.now() };
  return conversation.commit(async (tx) => {
    if (await assistantFailureAlreadyVisible(tx, conversation.id, body)) return;
    await writeFailureCard(tx, conversation.id, requestId, card);
  }, context);
}

/**
 * A generation fault ends its run, which gets the run's card (`faulted`). Compaction
 * failures already project as compaction_end. Other faulted or orphaned tasks do not.
 */
export function recordTaskFailure(
  conversation: Conversation,
  task: { id: TaskId; kind: string; message: string },
): Promise<void> {
  if (task.kind === "pi.compaction" || task.kind === "pi.generation") return Promise.resolve();
  const body = task.message.trim() || task.kind;
  return conversation.commit(
    (tx) =>
      writeFailureCard(tx, conversation.id, failureTaskRequestId(task.id), {
        title: "Task failed",
        body,
        at: Date.now(),
      }),
    context,
  );
}

function taskFailureBody(task: TaskRecord<JsonValue, JsonValue, JsonValue>): string | undefined {
  if (task.kind === "pi.compaction" || task.kind === "pi.generation") return undefined;
  if (task.state.status !== "terminal") return undefined;
  const outcome = task.state.outcome;
  if (outcome.status === "faulted") return outcome.error.message.trim() || task.kind;
  if (outcome.status === "orphaned") return outcome.reason.trim() || task.kind;
  return undefined;
}

/** `{ after }` is the continuation `scanTasks` returns. A stored task id resumes the same scan. */
function afterCursor(after: number): Cursor | undefined {
  return after > 0 ? { after } : undefined;
}

function parseWatermark(value: { readonly [key: string]: JsonValue }): {
  taskId: number;
  open: number[];
} {
  const taskId = value.taskId;
  const open = value.open;
  if (typeof taskId !== "number" || !Number.isSafeInteger(taskId) || taskId < 0) {
    throw new Error("Durable failure-card watermark is invalid");
  }
  if (!Array.isArray(open)) throw new Error("Durable failure-card watermark is invalid");
  const openIds: number[] = [];
  for (const id of open) {
    if (typeof id !== "number" || !Number.isSafeInteger(id) || id < 0) {
      throw new Error("Durable failure-card watermark is invalid");
    }
    openIds.push(id);
  }
  return { taskId, open: openIds };
}

async function readWatermark(
  storage: Storage,
  conversationId: ConversationId,
): Promise<{ taskId: number; open: number[] }> {
  const record = await storage.findDocument(
    {
      kind: FailureCardsDoc.definition.kind,
      scope: { kind: "conversation", conversationId },
    },
    "current",
    context,
  );
  if (!record) return { taskId: 0, open: [] };
  const stored = await storage.document(record.id, "current", context);
  if (!stored) return { taskId: 0, open: [] };
  return parseWatermark(stored.value);
}

/**
 * A crash between a run's end and its card write leaves the failure only in
 * `pi.live.runFailure`, until the next run starts; a faulted task leaves it only in the task
 * record, which the `oppi.failure-cards` watermark scans. Attach fills both. A failed scan
 * fails the attach. The request id makes a retry of a card that already landed a no-op.
 */
export async function reconcileFailureCards(
  harness: Harness,
  conversation: Conversation,
  storage: Storage,
): Promise<void> {
  const failure = (await harness.snapshot(LiveDoc, conversation.id, context))?.runFailure;
  if (failure) await recordRunFailure(conversation, failure);
  await reconcileTaskCards(conversation, storage);
}

async function reconcileTaskCards(conversation: Conversation, storage: Storage): Promise<void> {
  const mark = await readWatermark(storage, conversation.id);
  const open = new Set(mark.open);
  const candidates: TaskRecord<JsonValue, JsonValue, JsonValue>[] = [];
  for (const id of mark.open) {
    const task = await storage.task(id as TaskId, context);
    if (!task || task.conversationId !== conversation.id) {
      open.delete(id);
      continue;
    }
    if (task.state.status !== "terminal") continue;
    open.delete(id);
    candidates.push(task);
  }

  let examinedThrough = mark.taskId;
  let cursor = afterCursor(mark.taskId);
  do {
    const page = await storage.scanTasks(
      { conversationId: conversation.id },
      PAGE,
      cursor,
      context,
    );
    for (const task of page.items) {
      const id = Number(task.id);
      if (id > examinedThrough) examinedThrough = id;
      if (task.state.status !== "terminal") {
        open.add(id);
        continue;
      }
      open.delete(id);
      candidates.push(task);
    }
    cursor = page.next;
  } while (cursor !== undefined);

  const openIds = [...open].sort((a, b) => a - b);
  const watermarkMoved =
    examinedThrough !== mark.taskId ||
    openIds.length !== mark.open.length ||
    openIds.some((id, index) => id !== mark.open[index]);
  const cardTasks = candidates.filter((task) => taskFailureBody(task) !== undefined);
  if (!watermarkMoved && cardTasks.length === 0) return;

  await conversation.commit(async (tx) => {
    // Resolve every request id before the first append. A table read after a
    // table write is rejected, so the second card would roll this commit back
    // and the watermark would never advance.
    const missing: Array<{ requestId: string; body: string; at: number }> = [];
    for (const task of cardTasks) {
      const body = taskFailureBody(task);
      if (!body) continue;
      const requestId = failureTaskRequestId(task.id);
      if (await tx.submissionByRequest(conversation.id, requestId)) continue;
      missing.push({ requestId, body, at: Date.now() });
    }
    for (const card of missing) {
      await appendFailureCard(tx, conversation.id, card.requestId, {
        title: "Task failed",
        body: card.body,
        at: card.at,
      });
    }
    const doc = await tx.doc(FailureCardsDoc, conversation.id);
    doc.taskId = examinedThrough;
    doc.open = openIds;
  }, context);
}
