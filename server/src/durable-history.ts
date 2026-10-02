import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import type { ConversationId, EntryId, EntryRecord, Harness } from "@earendil-works/pi-durable";
import { performance } from "node:perf_hooks";
import {
  buildSessionContext,
  type SessionEntry,
  type TraceEvent,
  type TraceViewMode,
} from "./trace.js";
import { compactionSummary, isRecoveredPartial } from "./durable-event-projection.js";
import {
  readSessionTracePageFromEntries,
  tracePageCursorEntryId,
  type TracePageOptions,
  type TracePageResult,
} from "./trace-paging.js";
import { readSessionTraceOutlineFromEntries, type TraceOutlineResult } from "./trace-outline.js";
import type { MobileRendererRegistry } from "./mobile-renderer.js";

async function projectEntries(
  harness: Harness,
  records: readonly EntryRecord[],
): Promise<SessionEntry[]> {
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
        : message
          ? { type: "message", id: String(entry.id), parentId, timestamp, message }
          : // Display/bookkeeping entries have no model contribution. Preserve their
            // payload for the existing custom-entry renderer, never send it to the model.
            {
              type: "custom",
              id: String(entry.id),
              parentId,
              timestamp,
              customType: entry.kind,
              data: entry.data,
            },
    );
    parentId = String(entry.id);
  }
  return entries;
}

async function allEntries(harness: Harness, id: ConversationId): Promise<EntryRecord[]> {
  const conversation = await harness.conversation(id, context);
  if (!conversation) return [];
  const records = [];
  let cursor;
  do {
    const page = await conversation.entries({}, 500, cursor, context);
    records.push(...page.items);
    cursor = page.next;
  } while (cursor !== undefined);
  return records.reverse();
}

/** Read-only history on the process-owned Harness; never resumes scheduling. */
export async function readDurableTrace(
  harness: Harness,
  id: ConversationId,
  view: TraceViewMode,
): Promise<TraceEvent[]> {
  return buildSessionContext(await projectEntries(harness, await allEntries(harness, id)), {
    view,
  });
}

/** Ordinary pages scan only a newest-first ID-bounded window. Extend it when
 * hidden entries or an outstanding tool span need more evidence. Anchor jumps
 * need a full scan (tool/block IDs are not Durable entry IDs); outlines do too.
 */
export async function readDurableTracePage(
  harness: Harness,
  id: ConversationId,
  options: TracePageOptions,
): Promise<TracePageResult> {
  const start = performance.now();
  const sourceId = `durable:${id}`;
  const conversation = await harness.conversation(id, context);
  const target = Math.max(1, options.targetEvents ?? 450);
  let result: TracePageResult;
  if (!conversation || options.aroundEntryId) {
    result = readSessionTracePageFromEntries(
      await projectEntries(harness, await allEntries(harness, id)),
      sourceId,
      options,
    );
  } else {
    const anchorId = options.cursor ? tracePageCursorEntryId(options.cursor) : undefined;
    const maxEntryId =
      anchorId && /^\d+$/.test(anchorId) ? (Number(anchorId) as EntryId) : undefined;
    if (options.cursor && maxEntryId === undefined) {
      return readSessionTracePageFromEntries([], sourceId, options);
    }
    const records: EntryRecord[] = [];
    let cursor;
    do {
      const page = await conversation.entries(
        maxEntryId === undefined ? {} : { maxEntryId },
        Math.max(32, target + 1),
        cursor,
        context,
      );
      records.push(...page.items);
      cursor = page.next;
      const entries = await projectEntries(harness, [...records].reverse());
      result = readSessionTracePageFromEntries(entries, sourceId, options, cursor !== undefined);
      // A result at the lower window edge may have its call just outside it.
      // Keep reading until the shared selector can retain the whole tool span.
      const calls = new Set(
        entries.flatMap((entry) =>
          entry.message?.role === "assistant" && Array.isArray(entry.message.content)
            ? entry.message.content.flatMap((block) =>
                block.type === "toolCall" ? [block.id] : [],
              )
            : [],
        ),
      );
      const orphanResult = entries.some(
        (entry) =>
          entry.message?.role === "toolResult" && !calls.has(entry.message.toolCallId ?? ""),
      );
      if (result.page.staleCursor || (result.trace.length >= target && !orphanResult)) break;
    } while (cursor !== undefined);
  }
  // Version describes the conversation, not the bounded cursor window.
  const latest = await conversation?.entries({}, 1, undefined, context);
  result.page.traceVersion = `${sourceId}:${latest?.items[0]?.id ?? ""}`;
  result.metrics.readMs = Math.round((performance.now() - start) * 100) / 100;
  return result;
}

export async function readDurableTraceOutline(
  harness: Harness,
  id: ConversationId,
  mobileRenderers: MobileRendererRegistry,
): Promise<TraceOutlineResult> {
  const start = performance.now();
  const entries = await projectEntries(harness, await allEntries(harness, id));
  const result = readSessionTraceOutlineFromEntries(
    entries,
    `durable:${id}:${entries.at(-1)?.id ?? ""}`,
    { mobileRenderers },
  );
  result.metrics.readMs = Math.round((performance.now() - start) * 100) / 100;
  return result;
}
