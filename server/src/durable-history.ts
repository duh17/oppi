import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import {
  CompactionEntry,
  ResetEntry,
  type Conversation,
  type ConversationId,
  type EntryId,
  type EntryRecord,
  type Harness,
} from "@earendil-works/pi-durable";
import type { Message, NestedToolCalls as PiNestedToolCalls } from "@earendil-works/pi-ai";
import { performance } from "node:perf_hooks";
import {
  buildSessionContext,
  extractSearchTranscriptFromEntries,
  type SearchTranscriptContent,
  type SessionEntry,
  type LiveEntryRendererSet,
  type TraceEvent,
  type TraceViewMode,
} from "./trace.js";
import {
  readSessionTracePageFromEntries,
  tracePageCursorEntryId,
  tracePageRendererVersion,
  type TracePageOptions,
  type TracePageResult,
} from "./trace-paging.js";
import { readSessionTraceOutlineFromEntries, type TraceOutlineResult } from "./trace-outline.js";
import type { MobileRendererRegistry } from "./mobile-renderer.js";
import { sanitizeTranscriptCard } from "./durable-ui.js";
import {
  asCacheMissAssistantMessage,
  replayCacheMissHistory,
  type CacheMissModelPriceSource,
  type CacheMissNotice,
  type CacheMissNoticeSource,
  type CacheMissTrackerState,
} from "./cache-miss.js";
import { durableNestedCalls } from "./tool-nested-calls.js";
import { clientToolResult } from "./durable-tool-result-content.js";

import { readDurableInputCards } from "./durable-input-cards.js";

/** Hide only interrupted attempts whose SAME generation retries, never a user Stop.
 * A later assistant entry attributed to the same generation proves a retry even
 * if the user subsequently Stops it: hide earlier stubs, keep the latest Stop.
 * Otherwise a live non-abort-marked generation or completed/model-failed receipt
 * proves continuation; aborted/faulted/orphaned/unknown tasks stay visible.
 * Task attribution, not adjacency/text matching, also handles repeated crashes.
 * Shared by live projection, the conversation stream, and the durable history reader;
 * storage stays untouched. Callers pass `entries` holding the attempt's retry
 * when it lies past their window: see `readRetryEvidence`.
 */
export async function isRecoveredPartial(
  entry: EntryRecord,
  harness: Harness,
  entries: readonly EntryRecord[],
): Promise<boolean> {
  if (!isAbortedAttempt(entry)) return false;
  if (hasRetryEntry(entry, entries)) return true;
  const task = await harness.getTask(entry.byTaskId, context);
  if (!task || task.kind !== "pi.generation" || task.abortRequested) return false;
  return task.state.status !== "terminal" && task.state.status !== "completing"
    ? true
    : task.state.outcome.status === "completed" || task.state.outcome.status === "failed";
}

/** `entries` hold a later assistant entry of the attempt's own task: the part of the rule that needs no task record. */
export function hasRetryEntry(
  attempt: EntryRecord & { byTaskId: NonNullable<EntryRecord["byTaskId"]> },
  entries: readonly EntryRecord[],
): boolean {
  return entries.some(
    (later) =>
      later.id > attempt.id &&
      later.byTaskId === attempt.byTaskId &&
      later.model?.[0]?.role === "assistant",
  );
}

/**
 * Entries after `afterId`, oldest first, through the first assistant entry (or `maxEntryId`):
 * where the retry of an attempt that ended at or before `afterId` must be, since a
 * conversation runs one generation at a time. That entry is the bound: a reader never goes
 * past it, one 32-row page at a time, so a stopped attempt that never retried costs at most
 * the gap to the next answer.
 */
export async function readRetryEvidence(
  conversation: Conversation,
  afterId: number,
  maxEntryId?: number,
): Promise<EntryRecord[]> {
  const entries: EntryRecord[] = [];
  let cursor;
  do {
    const page = await conversation.entries(
      {
        minEntryId: (afterId + 1) as EntryId,
        ...(maxEntryId === undefined ? {} : { maxEntryId: maxEntryId as EntryId }),
        order: "ascending",
      },
      32,
      cursor,
      context,
    );
    for (const entry of page.items) {
      entries.push(entry);
      if (entry.model?.[0]?.role === "assistant") return entries;
    }
    cursor = page.next;
  } while (cursor !== undefined);
  return entries;
}

/**
 * Entries (oldest first) as `replayCacheMissHistory` reads them: each model message is a
 * saved message, a compaction or reset is the reset. `owners[i]` is the entry id behind
 * `history[i]`.
 */
export function durableCacheMissHistory(entries: readonly EntryRecord[]): {
  history: Array<{ type: "message"; message: unknown } | { type: "compaction" }>;
  owners: number[];
} {
  const history: Array<{ type: "message"; message: unknown } | { type: "compaction" }> = [];
  const owners: number[] = [];
  for (const entry of entries) {
    if (CompactionEntry.is(entry) || ResetEntry.is(entry)) {
      history.push({ type: "compaction" });
      owners.push(entry.id);
      continue;
    }
    for (const message of entry.model ?? []) {
      history.push({ type: "message", message });
      owners.push(entry.id);
    }
  }
  return { history, owners };
}

/**
 * Feed `entries` (oldest first, contiguous with what `tracker` saw) through `tracker`; the
 * notices of their answers by entry id.
 */
export function trackDurableCacheMisses(
  tracker: CacheMissTrackerState,
  entries: readonly EntryRecord[],
  models?: CacheMissModelPriceSource,
): Map<number, CacheMissNotice> {
  const { history, owners } = durableCacheMissHistory(entries);
  const notices = new Map<number, CacheMissNotice>();
  for (const { index, notice } of replayCacheMissHistory(tracker, history, models)) {
    const owner = owners[index];
    if (owner !== undefined) notices.set(owner, notice);
  }
  return notices;
}

/** Most entries `readCacheMissSeed` reads back. */
const CACHE_MISS_SEED_LIMIT = 200;

/**
 * The saved entries before `entryId` (oldest first) that leave a fresh tracker as a replay of
 * the whole history would: back to the newest answer that reported cache activity, or to the
 * newest compaction or reset. Usually one or two entries, so a page or a room starting at
 * `entryId` compares its first answer without reading the whole history. A provider that never
 * reports caching shows no notices, and its walk stops after `CACHE_MISS_SEED_LIMIT` entries.
 */
export async function readCacheMissSeed(
  conversation: Conversation,
  entryId: number,
): Promise<EntryRecord[]> {
  const seed: EntryRecord[] = [];
  let cursor;
  if (entryId > 1)
    do {
      const page = await conversation.entries(
        { maxEntryId: (entryId - 1) as EntryId },
        16,
        cursor,
        context,
      );
      for (const entry of page.items) {
        if (CompactionEntry.is(entry) || ResetEntry.is(entry)) return seed.reverse();
        seed.push(entry);
        const reportsCache = (entry.model ?? []).some((message) => {
          const usage = asCacheMissAssistantMessage(message)?.usage;
          return usage !== undefined && usage.cacheRead + usage.cacheWrite > 0;
        });
        if (reportsCache || seed.length >= CACHE_MISS_SEED_LIMIT) return seed.reverse();
      }
      cursor = page.next;
    } while (cursor !== undefined);
  return seed.reverse();
}

/** An aborted assistant entry a task committed: the only entries `isRecoveredPartial` may hide. */
export function isAbortedAttempt(
  entry: EntryRecord,
): entry is EntryRecord & { byTaskId: NonNullable<EntryRecord["byTaskId"]> } {
  const message = entry.model?.[0];
  return message?.role === "assistant" && message.stopReason === "aborted" && !!entry.byTaskId;
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

async function projectEntries(
  harness: Harness,
  records: readonly EntryRecord[],
  hiddenEntryIds?: ReadonlySet<EntryId>,
): Promise<SessionEntry[]> {
  const inputCards = await readDurableInputCards(
    harness,
    records.map((entry) => entry.conversationId),
  );
  const entries: SessionEntry[] = [];
  let parentId: string | null = null;
  for (const entry of records) {
    if (
      hiddenEntryIds
        ? hiddenEntryIds.has(entry.id)
        : await isRecoveredPartial(entry, harness, records)
    )
      continue;
    const message = withNestedCalls(clientToolResult(entry.model?.[0], entry.data));
    const timestamp = new Date(message?.timestamp ?? 0).toISOString();
    const data = entry.data;
    const card =
      inputCards.entries.get(entry.id) ??
      (!entry.model?.length
        ? sanitizeTranscriptCard(
            data && typeof data === "object" && !Array.isArray(data) ? data.card : undefined,
          )
        : undefined);
    entries.push(
      card
        ? {
            type: "custom",
            customType: entry.kind,
            data: inputCards.entries.has(entry.id) ? { card, inputCard: true } : entry.data,
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
            ? {
                type: "message",
                id: String(entry.id),
                parentId,
                timestamp,
                message,
                // An input placed as an application kind (an agent message) keeps
                // its kind and data for the trace; `pi.*` kinds are plain messages.
                ...(entry.kind.startsWith("pi.")
                  ? {}
                  : { customType: entry.kind, data: entry.data }),
              }
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

/**
 * A durable tool result with the nested calls its details list where Pi records them
 * (`nestedCalls`), so the trace shows them as the conversation stream's `toolResult` does.
 */
function withNestedCalls(message: Message | undefined): Message | undefined {
  if (message?.role !== "toolResult") return message;
  const nestedCalls = durableNestedCalls(message.toolCallId, message.details);
  // Statuses stay open strings ("cancelled"), which the trace keeps as the stream does.
  return nestedCalls ? { ...message, nestedCalls: nestedCalls as PiNestedToolCalls } : message;
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

/** Every entry of the conversation as Pi session entries, oldest first: what traces and exports read. */
export async function readDurableSessionEntries(
  harness: Harness,
  id: ConversationId,
): Promise<SessionEntry[]> {
  return projectEntries(harness, await allEntries(harness, id));
}

/** Read-only history on the process-owned Harness; never resumes scheduling. */
export async function readDurableTrace(
  harness: Harness,
  id: ConversationId,
  view: TraceViewMode,
  entryRenderers?: LiveEntryRendererSet,
  /** Where user-message image bytes are stored; without it they stay data URIs. */
  images?: { dataDir: string; sessionId: string },
  cacheMissNotices?: CacheMissNoticeSource,
): Promise<TraceEvent[]> {
  return buildSessionContext(await projectEntries(harness, await allEntries(harness, id)), {
    view,
    entryRenderers,
    ...(cacheMissNotices ? { cacheMissNotices } : {}),
    ...(images ? { attachmentDataDir: images.dataDir, attachmentSessionId: images.sessionId } : {}),
  });
}

/** Newest entry id, the harness-native freshness marker for derived read models ("" if none). */
export async function readDurableTipEntryId(harness: Harness, id: ConversationId): Promise<string> {
  const conversation = await harness.conversation(id, context);
  const latest = await conversation?.entries({}, 1, undefined, context);
  const tip = latest?.items[0]?.id;
  return tip === undefined ? "" : String(tip);
}

/** FTS fields for search, extracted from the same projection the traces use. */
export async function readDurableSearchTranscript(
  harness: Harness,
  id: ConversationId,
): Promise<SearchTranscriptContent> {
  return extractSearchTranscriptFromEntries(
    await projectEntries(harness, await allEntries(harness, id)),
  );
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
  const rendererVersion = tracePageRendererVersion(options);

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
    let newer: EntryRecord[] | undefined;
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
      // A window cannot decide recovery from its prefix alone: an attempt with no retry
      // in it may have one just past its newest entry. Read that once, bounded by the
      // captured tip (the window's newest entry never changes between iterations).
      const windowTip = records[0]?.id;
      if (
        !newer &&
        windowTip !== undefined &&
        tip !== undefined &&
        windowTip < tip &&
        records.some((entry) => isAbortedAttempt(entry) && !hasRetryEntry(entry, records))
      )
        newer = await readRetryEvidence(conversation, windowTip, tip);
      result = await pageFromRecords(
        [...records].reverse(),
        newer ? [...records, ...newer] : records,
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
