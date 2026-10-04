import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import type {
  ConversationId,
  EntryId,
  Harness,
  SubmissionId,
  Tx,
} from "@earendil-works/pi-durable";
import {
  DurableInputCards,
  sanitizeTranscriptCard,
  type TranscriptCard,
} from "../extensions/durable/durable-ui.js";

type InputCards = {
  entries: Map<EntryId, TranscriptCard>;
  submissions: Set<SubmissionId>;
};

/** Resolve metadata and receipts on the same mutation line. Also used by queue
 * edits: generated inputs are not user-editable messages and retain their IDs.
 */
export async function resolveDurableInputCards(tx: Tx, id: ConversationId): Promise<InputCards> {
  const entries = new Map<EntryId, TranscriptCard>();
  const submissions = new Set<SubmissionId>();
  const metadata = await tx.doc(DurableInputCards, id);
  for (const [requestId, value] of Object.entries(metadata.requests)) {
    const card = sanitizeTranscriptCard(value);
    if (!card) continue;
    const receipt = await tx.submissionByRequest(id, requestId);
    if (receipt?.type !== "input") continue;
    submissions.add(receipt.id);
    if (receipt.entry !== undefined) entries.set(receipt.entry, card);
  }
  return { entries, submissions };
}

/** Resolve presentation by receipt identity, never input text or extension name.
 * History reads neither create documents nor resume the scheduler. Inherited
 * entries use their original conversation's metadata.
 */
export async function readDurableInputCards(
  harness: Harness,
  ids: Iterable<ConversationId>,
): Promise<InputCards> {
  const entries = new Map<EntryId, TranscriptCard>();
  const submissions = new Set<SubmissionId>();
  for (const id of new Set(ids)) {
    // Existence only: do not capture metadata outside the receipt transaction.
    if (!(await harness.snapshot(DurableInputCards, id, context))) continue;
    const resolved = await harness.commit((tx) => resolveDurableInputCards(tx, id), context);
    for (const [entry, card] of resolved.entries) entries.set(entry, card);
    for (const submission of resolved.submissions) submissions.add(submission);
  }
  return { entries, submissions };
}

/** Read the explicitly advertised slice, scoped to the session's visible ancestry.
 * No background-job naming/text heuristics; no raw model prompt returned.
 */
export async function readDurableInputCardOutput(
  harness: Harness,
  id: ConversationId,
  entryId: string,
): Promise<{ output: string } | null> {
  if (!/^[1-9]\d*$/.test(entryId) || !Number.isSafeInteger(Number(entryId))) return null;
  const conversation = await harness.conversation(id, context);
  if (!conversation) return null;
  const numericId = Number(entryId) as EntryId;
  const page = await conversation.entries(
    { minEntryId: numericId, maxEntryId: numericId },
    1,
    undefined,
    context,
  );
  const entry = page.items.find((item) => item.id === numericId);
  if (!entry) return null;
  const cards = await readDurableInputCards(harness, [entry.conversationId]);
  const output = cards.entries.get(entry.id)?.output;
  if (!output) return null;
  const message = entry.model?.[0];
  if (message?.role !== "user") return null;
  const text =
    typeof message.content === "string"
      ? message.content
      : message.content
          .filter((part) => part.type === "text")
          .map((part) => part.text)
          .join("\n");
  if (output.offset + output.length > text.length) return null;
  return { output: text.slice(output.offset, output.offset + output.length) };
}
