import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import type { ConversationId, Harness } from "@earendil-works/pi-durable";
import {
  CONVERSATION_CLIENT_DOCS,
  projectEntry,
  renderToolCall,
  toolCallsOf,
  type ToolPresenter,
} from "../../src/durable-conversation-view.js";
import type { MobileRendererRegistry } from "../../src/mobile-renderer.js";
import type { ConversationEntryView } from "../../src/types.js";

export interface ConversationReference {
  head: number;
  entries: ConversationEntryView[];
  docs: Record<string, unknown>;
}

/**
 * What a replica must converge to, read from the Harness without a stream room: the
 * conversation view's active entries and the committed client documents, through the
 * client projection, wire-roundtripped like a frame.
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
  const first = view.entries[0];
  return JSON.parse(
    JSON.stringify({
      head: first?.head !== undefined ? first.id : 0,
      entries: view.entries.map((entry) => projectEntry(entry, renderers, tools)),
      docs,
    }),
  ) as ConversationReference;
}
