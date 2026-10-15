import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import type { ConversationId, Harness } from "@earendil-works/pi-durable";
import {
  CONVERSATION_CLIENT_DOCS,
  projectEntry,
  renderToolCall,
  toolCallsOf,
  type ToolPresenter,
} from "../../src/durable-conversation-view.js";
import { isRecoveredPartial } from "../../src/durable-history.js";
import { readDurableInputCards } from "../../src/durable-input-cards.js";
import type { MobileRendererRegistry } from "../../src/mobile-renderer.js";
import type { ConversationEntryView } from "../../src/types.js";

/**
 * The replica's upsert rule: replace an entry it holds; place one it does not hold in id
 * order after the head entry (which stays first).
 */
export function upsertEntries(
  entries: readonly ConversationEntryView[],
  head: number,
  incoming: readonly ConversationEntryView[],
): ConversationEntryView[] {
  const result = [...entries];
  for (const entry of incoming) {
    const index = result.findIndex((candidate) => candidate.id === entry.id);
    if (index >= 0) {
      result[index] = entry;
      continue;
    }
    const start = result[0]?.id === head && head !== 0 ? 1 : 0;
    let at = result.length;
    for (let candidate = start; candidate < result.length; candidate += 1)
      if (result[candidate]!.id > entry.id) {
        at = candidate;
        break;
      }
    result.splice(at, 0, entry);
  }
  return result;
}

/** Entries a replica shows: everything it holds except hidden ones. */
export function shownEntries(entries: readonly ConversationEntryView[]): ConversationEntryView[] {
  return entries.filter((entry) => !entry.hidden);
}

export interface ConversationReference {
  head: number;
  /** Shown active entries in display order. */
  entries: ConversationEntryView[];
  docs: Record<string, unknown>;
}

/**
 * What a replica must converge to, read from the Harness without a stream room: the
 * conversation view's active entries with the presentation trace history gives them, and
 * the committed client documents, through the client projection, wire-roundtripped like a
 * frame.
 */
export async function conversationReference(
  harness: Harness,
  conversationId: ConversationId,
  renderers: MobileRendererRegistry,
): Promise<ConversationReference> {
  const conversation = await harness.conversation(conversationId, context);
  if (!conversation) throw new Error(`Durable conversation ${conversationId} is missing`);
  const state = await conversation.viewState(context);
  const view = state.value;
  state.dispose();
  const calls = new Map<string, { name: string; args: unknown }>();
  for (const entry of view.entries)
    for (const message of entry.model ?? [])
      if (message.role === "assistant")
        for (const call of toolCallsOf(message))
          calls.set(call.id, { name: call.name, args: call.args });
  const tools: ToolPresenter = {
    call: (name, args) => renderToolCall(renderers, name, args),
    committedCall: (callId) => calls.get(callId),
  };
  const docs: Record<string, unknown> = {};
  for (const spec of CONVERSATION_CLIENT_DOCS) {
    const value = await harness.snapshot(spec.doc, conversationId, context);
    if (value) docs[spec.kind] = spec.project(value, tools);
  }
  const cards = await readDurableInputCards(
    harness,
    view.entries.map((entry) => entry.conversationId),
  );
  const entries: ConversationEntryView[] = [];
  for (const entry of view.entries)
    if (!(await isRecoveredPartial(entry, harness, view.entries)))
      entries.push(
        projectEntry(entry, renderers, tools, { inputCard: cards.entries.get(entry.id) }),
      );
  const first = view.entries[0];
  return JSON.parse(
    JSON.stringify({ head: first?.head !== undefined ? first.id : 0, entries, docs }),
  ) as ConversationReference;
}
