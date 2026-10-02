import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import type { ConversationId, EntryId, EntryRecord, Harness } from "@earendil-works/pi-durable";
import { performance } from "node:perf_hooks";
import {
  buildSessionContext,
  type SessionEntry,
  type LiveEntryRendererSet,
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
import { sanitizeTranscriptCard } from "../extensions/durable/durable-ui.js";

async function projectEntries(
  harness: Harness,
  records: readonly EntryRecord[],
  hiddenEntryIds?: ReadonlySet<EntryId>,
): Promise<SessionEntry[]> {
  const entries: SessionEntry[] = [];
  let parentId: string | null = null;
  for (const entry of records) {
    if (
      hiddenEntryIds
        ? hiddenEntryIds.has(entry.id)
        : await isRecoveredPartial(entry, harness, records)
    )
      continue;
    const message = entry.model?.[0];
    const timestamp = new Date(message?.timestamp ?? 0).toISOString();
    const data = entry.data;
    const card = !entry.model?.length
      ? sanitizeTranscriptCard(
          data && typeof data === "object" && !Array.isArray(data) ? data.card : undefined,
        )
      : undefined;
    entries.push(
      card
        ? {
            type: "custom",
            customType: entry.kind,
            data: entry.data,
            id: String(entry.id),
            parentId,
            timestamp: new Date(card.at).toISOString(),
          }
        : entry.kind === "pi.compaction"
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
  entryRenderers?: LiveEntryRendererSet,
): Promise<TraceEvent[]> {
  return buildSessionContext(await projectEntries(harness, await allEntries(harness, id)), {
    view,
    entryRenderers,
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
  const latest = await conversation?.entries({}, 1, undefined, context);
  const tip = latest?.items[0]?.id;
  const rendererVersion = options.entryRenderers?.version ?? "";

  async function pageFromRecords(
    records: readonly EntryRecord[],
    recoveryEvidence: readonly EntryRecord[],
    hasOlder = false,
  ): Promise<TracePageResult> {
    const hidden = new Set<EntryId>();
    for (const entry of records) {
      if (await isRecoveredPartial(entry, harness, recoveryEvidence)) hidden.add(entry.id);
    }
    const hiddenCalls = new Set(
      records.flatMap((entry) => {
        const content = entry.model?.[0]?.content;
        return hidden.has(entry.id) && Array.isArray(content)
          ? content.flatMap((block) => (block.type === "toolCall" ? [block.id] : []))
          : [];
      }),
    );
    const resultCalls = new Map<string, string>();
    const entries = (await projectEntries(harness, records, hidden)).map((entry) => {
      const message = entry.message;
      if (
        message?.role !== "toolResult" ||
        !message.toolCallId ||
        !hiddenCalls.has(message.toolCallId)
      )
        return entry;
      // The full trace keeps these results without their recovered call. Treat
      // them as standalone for selection, then restore their original identity.
      // Do not change JSONL's independent call/result grouping contract.
      resultCalls.set(`result-${entry.id}`, message.toolCallId);
      return { ...entry, message: { ...message, toolCallId: undefined } };
    });
    const page = readSessionTracePageFromEntries(entries, sourceId, options, hasOlder);
    page.trace = page.trace.map((event) => {
      const toolCallId = resultCalls.get(event.id);
      return toolCallId ? { ...event, toolCallId } : event;
    });
    return page;
  }

  let result: TracePageResult;
  if (!conversation || options.aroundEntryId) {
    const records = await allEntries(harness, id);
    result = await pageFromRecords(records, records);
  } else {
    const anchorId = options.cursor ? tracePageCursorEntryId(options.cursor) : undefined;
    const maxEntryId =
      anchorId && /^\d+$/.test(anchorId) ? (Number(anchorId) as EntryId) : undefined;
    if (options.cursor && maxEntryId === undefined) {
      return readSessionTracePageFromEntries([], sourceId, options);
    }
    const records: EntryRecord[] = [];
    const newerRecords: EntryRecord[] = [];
    let newerCursor;
    let newerExhausted = false;
    let cursor;
    do {
      const page = await conversation.entries(
        maxEntryId === undefined ? (tip === undefined ? {} : { maxEntryId: tip }) : { maxEntryId },
        Math.max(32, target + 1),
        cursor,
        context,
      );
      records.push(...page.items);
      cursor = page.next;
      // Cursor windows cannot decide recovery from their prefix alone. Only
      // aborted assistants need forward evidence: stop as soon as each task has
      // a newer assistant, or after exhausting the range through the captured tip.
      const pending = new Set(
        records
          .filter(
            (entry) =>
              entry.model?.[0]?.role === "assistant" &&
              entry.model[0].stopReason === "aborted" &&
              entry.byTaskId &&
              ![...records, ...newerRecords].some(
                (later) =>
                  later.id > entry.id &&
                  later.byTaskId === entry.byTaskId &&
                  later.model?.[0]?.role === "assistant",
              ),
          )
          .map((entry) => entry.byTaskId!),
      );
      const windowTip = records[0]?.id;
      while (
        pending.size &&
        !newerExhausted &&
        windowTip !== undefined &&
        tip !== undefined &&
        windowTip < tip
      ) {
        const newer = await conversation.entries(
          { minEntryId: (windowTip + 1) as EntryId, maxEntryId: tip },
          Math.max(32, target + 1),
          newerCursor,
          context,
        );
        newerRecords.push(...newer.items);
        for (const entry of newer.items) {
          if (entry.byTaskId && entry.model?.[0]?.role === "assistant")
            pending.delete(entry.byTaskId);
        }
        newerCursor = newer.next;
        newerExhausted = newerCursor === undefined;
      }
      result = await pageFromRecords(
        [...records].reverse(),
        [...records, ...newerRecords],
        cursor !== undefined,
      );
      // A result at the lower window edge may have its call just outside it.
      // Keep reading until the shared selector can retain the whole tool span.
      const calls = new Set(
        records.flatMap((entry) =>
          entry.model?.[0]?.role === "assistant" && Array.isArray(entry.model[0].content)
            ? entry.model[0].content.flatMap((block) =>
                block.type === "toolCall" ? [block.id] : [],
              )
            : [],
        ),
      );
      const orphanResult = records.some(
        (entry) => entry.model?.[0]?.role === "toolResult" && !calls.has(entry.model[0].toolCallId),
      );
      // A result cursor may need its hidden call before its selection-only hash
      // can be validated. Resolve outstanding calls before declaring it stale.
      if (!orphanResult && (result.page.staleCursor || result.trace.length >= target)) break;
    } while (cursor !== undefined);
  }
  // Version describes the conversation, not the bounded cursor window.
  result.page.traceVersion = `${sourceId}:${tip ?? ""}${rendererVersion ? `:r${rendererVersion}` : ""}`;
  result.metrics.readMs = Math.round((performance.now() - start) * 100) / 100;
  return result;
}

export async function readDurableTraceOutline(
  harness: Harness,
  id: ConversationId,
  mobileRenderers: MobileRendererRegistry,
  entryRenderers?: LiveEntryRendererSet,
): Promise<TraceOutlineResult> {
  const start = performance.now();
  const entries = await projectEntries(harness, await allEntries(harness, id));
  const result = readSessionTraceOutlineFromEntries(
    entries,
    `durable:${id}:${entries.at(-1)?.id ?? ""}`,
    { mobileRenderers, entryRenderers },
  );
  result.metrics.readMs = Math.round((performance.now() - start) * 100) / 100;
  return result;
}
