import { existsSync } from "node:fs";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import type {
  Conversation,
  Cursor,
  EntryRecord,
  SubmissionId,
  SubmissionRecord,
  TaskId,
  TaskRecord,
} from "@earendil-works/pi-durable";
import type { JsonValue } from "@earendil-works/chord";
import { DURABLE_FAILURE_REQUEST_ID_PREFIX } from "./durable-request-ids.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import { openDatabase } from "./sqlite-compat.js";

const log = createLogger({ base: { component: "durable-failure-cards" } });

/** Display-only transcript row. Not a model message, and not `oppi-` (that prefix is hidden). */
export const DURABLE_FAILURE_ENTRY_KIND = "oppi.failure";

/** Queue withdrawal and an explicit Stop settle `aborted`. `withdrawn` is reserved for the same quiet end. */
const QUIET_UNANSWERED_REASONS = new Set(["aborted", "withdrawn"]);

function failureInputRequestId(id: SubmissionId): string {
  return `${DURABLE_FAILURE_REQUEST_ID_PREFIX}input:${id}`;
}

function failureTaskRequestId(id: TaskId): string {
  return `${DURABLE_FAILURE_REQUEST_ID_PREFIX}task:${id}`;
}

function isRecordedInputFailure(reason: string): boolean {
  return !QUIET_UNANSWERED_REASONS.has(reason);
}

/**
 * History renders assistant text, thinking, and tool calls. It does not render
 * `errorMessage`, so a `stopReason: "error"` entry is not already the failure row.
 * Skip the card only when that same text is already visible, which would be a second row.
 */
function assistantFailureAlreadyVisible(entries: readonly EntryRecord[], text: string): boolean {
  const needle = text.trim();
  if (!needle) return false;
  for (const entry of entries) {
    const message = entry.model?.[0];
    if (message?.role !== "assistant" || message.stopReason !== "error") continue;
    const content = message.content;
    const visible =
      typeof content === "string"
        ? content
        : Array.isArray(content)
          ? content
              .flatMap((block) => (block.type === "text" && block.text ? [block.text] : []))
              .join("\n")
          : "";
    if (visible.includes(needle)) return true;
  }
  return false;
}

function failureBody(reason: string, detail: JsonValue | undefined): string {
  return typeof detail === "string" && detail.trim() ? detail : reason;
}

async function listEntries(conversation: Conversation): Promise<EntryRecord[]> {
  const records: EntryRecord[] = [];
  let cursor: Cursor | undefined;
  do {
    const page = await conversation.entries({}, 500, cursor, context);
    records.push(...page.items);
    cursor = page.next;
  } while (cursor !== undefined);
  return records;
}

/** Append a display-only card once. A known request id returns the existing write. */
async function commitFailureCard(
  conversation: Conversation,
  requestId: string,
  card: { title: string; body: string; status?: string; at: number },
): Promise<void> {
  await conversation.commit(async (tx) => {
    if (await tx.submissionByRequest(conversation.id, requestId)) return;
    const entry = await tx.appendEntry(conversation.id, {
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
      conversationId: conversation.id,
      requestId,
      type: "write",
      status: "done",
      entry: entry.id,
    });
  }, context);
}

export async function recordInputFailure(
  conversation: Conversation,
  settled: Extract<SubmissionRecord, { type: "input"; status: "unanswered" }>,
): Promise<void> {
  if (!isRecordedInputFailure(settled.reason)) return;
  const body = failureBody(settled.reason, settled.detail);
  // Trace history does not project errorMessage. The card is that row unless the
  // assistant text already shows the same failure.
  if (assistantFailureAlreadyVisible(await listEntries(conversation), body)) return;
  await commitFailureCard(conversation, failureInputRequestId(settled.id), {
    title: "Run failed",
    body,
    status: settled.reason,
    at: Date.now(),
  });
}

/**
 * Generation faults settle the run's inputs, which get the input card. Compaction
 * failures already project as compaction_end. Other faulted or orphaned tasks do not.
 */
export async function recordTaskFailure(
  conversation: Conversation,
  task: { id: TaskId; kind: string; message: string },
): Promise<void> {
  if (task.kind === "pi.compaction" || task.kind === "pi.generation") return;
  const body = task.message.trim() || task.kind;
  await commitFailureCard(conversation, failureTaskRequestId(task.id), {
    title: "Task failed",
    body,
    at: Date.now(),
  });
}

function readUnansweredInputs(sqlitePath: string, conversationId: number): SubmissionRecord[] {
  if (!existsSync(sqlitePath)) return [];
  const db = openDatabase(sqlitePath, { readonly: true });
  try {
    const rows = db
      .prepare("SELECT record FROM submissions WHERE conversation_id = ? AND status = 'unanswered'")
      .all(conversationId) as Array<{ record: string }>;
    return rows.flatMap((row) => {
      const record = JSON.parse(row.record) as SubmissionRecord;
      return record.type === "input" && record.status === "unanswered" ? [record] : [];
    });
  } finally {
    db.close();
  }
}

async function terminalTasks(
  conversation: Conversation,
): Promise<TaskRecord<JsonValue, JsonValue, JsonValue>[]> {
  const tasks: TaskRecord<JsonValue, JsonValue, JsonValue>[] = [];
  let cursor: Cursor | undefined;
  do {
    const page = await conversation.commit(
      (tx) => tx.scanTasks({ conversationId: conversation.id, status: "terminal" }, 100, cursor),
      context,
    );
    tasks.push(...page.items);
    cursor = page.next;
  } while (cursor !== undefined);
  return tasks;
}

/**
 * A crash between settlement and the card write leaves the failure only in the
 * submission or task record. Attach fills those cards. The request id makes a
 * retry of a card that already landed a no-op. Tx has no submission scan, so
 * unanswered inputs are read from the harness SQLite record column.
 */
export async function reconcileFailureCards(
  conversation: Conversation,
  sqlitePath: string,
): Promise<void> {
  let inputs: SubmissionRecord[] = [];
  try {
    inputs = readUnansweredInputs(sqlitePath, Number(conversation.id));
  } catch (error) {
    log.warn("durable_failure.reconcile_read_failed", { error: safeErrorMessage(error) });
  }
  for (const input of inputs) {
    if (input.type !== "input" || input.status !== "unanswered") continue;
    try {
      await recordInputFailure(conversation, input);
    } catch (error) {
      log.warn("durable_failure.input_card_failed", {
        submissionId: input.id,
        error: safeErrorMessage(error),
      });
    }
  }
  let tasks: TaskRecord<JsonValue, JsonValue, JsonValue>[] = [];
  try {
    tasks = await terminalTasks(conversation);
  } catch (error) {
    log.warn("durable_failure.reconcile_tasks_failed", { error: safeErrorMessage(error) });
  }
  for (const task of tasks) {
    if (task.state.status !== "terminal") continue;
    const outcome = task.state.outcome;
    if (outcome.status !== "faulted" && outcome.status !== "orphaned") continue;
    const message = outcome.status === "faulted" ? outcome.error.message : outcome.reason;
    try {
      await recordTaskFailure(conversation, { id: task.id, kind: task.kind, message });
    } catch (error) {
      log.warn("durable_failure.task_card_failed", {
        taskId: task.id,
        error: safeErrorMessage(error),
      });
    }
  }
}
