import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import type { ConversationId, Harness } from "@earendil-works/pi-durable";
import {
  buildSessionContext,
  type SessionEntry,
  type TraceEvent,
  type TraceViewMode,
} from "./trace.js";
import { compactionSummary, isRecoveredPartial } from "./durable-event-projection.js";

/** Read-only history on the process-owned Harness; never resumes scheduling. */
export async function readDurableTrace(
  harness: Harness,
  id: ConversationId,
  view: TraceViewMode,
): Promise<TraceEvent[]> {
  const conversation = await harness.conversation(id, context);
  if (!conversation) return [];
  const records = [];
  let cursor;
  do {
    const page = await conversation.entries({}, 500, cursor, context);
    records.push(...page.items);
    cursor = page.next;
  } while (cursor !== undefined);
  records.reverse();
  const entries: SessionEntry[] = [];
  let parentId: string | null = null;
  for (const entry of records) {
    if (await isRecoveredPartial(entry, harness, records)) continue;
    const message = entry.model?.[0];
    const timestamp = new Date(message?.timestamp ?? 0).toISOString();
    entries.push(
      entry.kind === "pi.compaction"
        ? {
            type: "compaction",
            id: String(entry.id),
            parentId,
            timestamp,
            summary: compactionSummary(entry),
            firstKeptEntryId: String(entry.head),
          }
        : {
            type: "message",
            id: String(entry.id),
            parentId,
            timestamp,
            message,
          },
    );
    parentId = String(entry.id);
  }
  return buildSessionContext(entries, { view });
}
