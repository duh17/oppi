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
