/**
 * Client projection of a durable conversation for the conversation stream:
 * which documents clients replicate, and the tool presentation the server adds
 * to entries and `pi.live`. Pure functions over committed values; the room in
 * `durable-conversation-stream.ts` owns state and delivery.
 */
import type { Message } from "@earendil-works/pi-ai";
import {
  AgentDoc,
  InboxDoc,
  LiveDoc,
  UsageDoc,
  type ConversationDocToken,
  type EntryRecord,
  type JsonObject,
  type LiveState,
  type ToolSlot,
} from "@earendil-works/pi-durable";
import type { JsonValue } from "@earendil-works/chord";
import { DurableUIClientDoc, sanitizeTranscriptCard } from "../extensions/durable/durable-ui.js";
import { normalizeAudioPresentationDetails } from "./audio-presentation.js";
import { resolveToolDisplay, type MobileRendererRegistry } from "./mobile-renderer.js";
import type {
  ConversationEntryCard,
  ConversationEntryView,
  ConversationToolCallView,
  ConversationToolResultView,
} from "./types.js";
import { sanitizeToolResultDetails } from "./visual-schema.js";

/**
 * Visibility metadata: a conversation document clients replicate. Every other
 * document stays on the server. `view` projects the committed value for clients
 * and must be pure; without it the committed value is sent as is.
 */
export interface ClientDoc<T extends JsonObject> {
  readonly doc: ConversationDocToken<T>;
  readonly client: true;
  readonly view?: (value: T, tools: ToolPresenter) => object;
}

/** Tool presentation shared by entry views and the live view. */
export interface ToolPresenter {
  call(name: string, args: unknown): ConversationToolCallView;
  /** Name and arguments of a committed tool call in the active entries. */
  committedCall(callId: string): { name: string; args: unknown } | undefined;
}

/** A client document with its value type erased, for iteration. */
export interface ClientDocSpec {
  readonly kind: string;
  readonly doc: ConversationDocToken<JsonObject>;
  project(value: JsonObject, tools: ToolPresenter): JsonObject;
}

function clientDoc<T extends JsonObject>(spec: ClientDoc<T>): ClientDocSpec {
  const view = spec.view;
  return {
    kind: spec.doc.definition.kind,
    doc: spec.doc as unknown as ConversationDocToken<JsonObject>,
    project: (value, tools) => (view ? view(value as T, tools) : value) as JsonObject,
  };
}

/**
 * The documents clients replicate. Pi built-ins Oppi shows (`pi.provider` stays
 * private), then extension documents that declare themselves client-visible.
 */
export const CONVERSATION_CLIENT_DOCS: readonly ClientDocSpec[] = [
  clientDoc({ doc: LiveDoc, client: true, view: liveView }),
  clientDoc({ doc: InboxDoc, client: true }),
  clientDoc({ doc: AgentDoc, client: true }),
  clientDoc({ doc: UsageDoc, client: true }),
  clientDoc(DurableUIClientDoc),
];

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function argsRecord(args: unknown): Record<string, unknown> {
  return asRecord(args) ?? {};
}

/** Tool calls in an assistant message, in content order. */
export function toolCallsOf(message: unknown): Array<{ id: string; name: string; args: unknown }> {
  const content = asRecord(message)?.content;
  if (!Array.isArray(content)) return [];
  const calls = [];
  for (const block of content) {
    const record = asRecord(block);
    if (record?.type !== "toolCall") continue;
    if (typeof record.id !== "string" || typeof record.name !== "string") continue;
    calls.push({ id: record.id, name: record.name, args: record.arguments });
  }
  return calls;
}

/** The same call presentation as classic `tool_start`. */
export function renderToolCall(
  renderers: MobileRendererRegistry,
  name: string,
  args: unknown,
): ConversationToolCallView {
  const callSegments = renderers.renderCall(name, argsRecord(args));
  const display = resolveToolDisplay(name);
  const inputPresentation = renderers.inputPresentation(name);
  const outputPresentation = renderers.outputPresentation(name);
  return {
    ...(callSegments ? { callSegments } : {}),
    ...(display ? { display } : {}),
    ...(inputPresentation ? { inputPresentation } : {}),
    ...(outputPresentation ? { outputPresentation } : {}),
  };
}

/** The same result presentation as classic `tool_end` and trace history. */
function renderToolResult(
  renderers: MobileRendererRegistry,
  message: Extract<Message, { role: "toolResult" }>,
  rawDetails: unknown,
  details: unknown,
): ConversationToolResultView {
  const resultSegments = renderers.renderResult(
    message.toolName,
    details,
    message.isError === true,
  );
  const outputPresentation = renderers.outputPresentation(message.toolName, rawDetails);
  const display = resolveToolDisplay(message.toolName, undefined, rawDetails);
  return {
    ...(resultSegments ? { resultSegments } : {}),
    ...(outputPresentation ? { outputPresentation } : {}),
    outputAvailability: renderers.outputAvailability(rawDetails),
    ...(display ? { display } : {}),
  };
}

/**
 * How the trace shows an entry beyond its content, decided by the caller from state outside
 * the entry: `inputCard` from `readDurableInputCards`, `hidden` from `isRecoveredPartial`.
 */
export interface EntryPresentation {
  inputCard?: ConversationEntryCard;
  hidden?: boolean;
}

/**
 * `EntryRecord` without storage internals, plus the presentation trace history gives it
 * (`projectEntries` in `durable-history.ts`): tool rendering, cards, and hiding.
 */
export function projectEntry(
  entry: EntryRecord,
  renderers: MobileRendererRegistry,
  tools: ToolPresenter,
  presentation: EntryPresentation = {},
): ConversationEntryView {
  const view: ConversationEntryView = { id: entry.id, kind: entry.kind };
  if (presentation.hidden) return { ...view, hidden: true };
  // Like the trace, an extension-generated input shows only its card, never the raw input.
  if (presentation.inputCard) return { ...view, card: presentation.inputCard, inputCard: true };
  if (entry.model) {
    const model: Message[] = [];
    for (const message of entry.model) {
      if (message.role !== "toolResult") {
        model.push(message);
        continue;
      }
      // Trace history normalizes audio and strips server-private paths at the client
      // boundary; so does the stream.
      const raw =
        message.details === undefined
          ? undefined
          : normalizeAudioPresentationDetails(message.details);
      const details = raw === undefined ? undefined : sanitizeToolResultDetails(raw).details;
      model.push(
        details === message.details ? message : { ...message, details: details as JsonValue },
      );
      view.toolResult = renderToolResult(renderers, message, raw, details);
    }
    view.model = model;
    const calls = entry.model.flatMap((message) =>
      message.role === "assistant" ? toolCallsOf(message) : [],
    );
    if (calls.length) {
      view.toolCalls = {};
      for (const call of calls) view.toolCalls[call.id] = tools.call(call.name, call.args);
    }
  }
  // Raw `data` stays on the server: it is extension bookkeeping that can hold private paths.
  // Clients get only the sanitized card, as trace history shows it.
  if (!entry.model?.length) {
    const data = asRecord(entry.data);
    const card = sanitizeTranscriptCard(data?.card);
    if (card) view.card = card;
  }
  return view;
}

/**
 * `pi.live` plus `toolCalls`: presentation by call id for the streaming answer's tool
 * calls and the running tool round. Slot `details` are sanitized like results.
 */
function liveView(value: LiveState, tools: ToolPresenter): object {
  const toolCalls: Record<string, ConversationToolCallView> = {};
  for (const call of toolCallsOf(value.generation?.message))
    toolCalls[call.id] = tools.call(call.name, call.args);
  const committed = value.tools ?? [];
  // Copied only when a slot's details need sanitizing.
  let slots: ToolSlot[] | undefined;
  for (const [index, slot] of committed.entries()) {
    toolCalls[slot.callId] ??= tools.call(slot.name, tools.committedCall(slot.callId)?.args ?? {});
    if (slot.details === undefined) continue;
    const details = sanitizeToolResultDetails(slot.details).details;
    if (details === slot.details) continue;
    slots ??= [...committed];
    slots[index] = { ...slot, details: details as JsonValue };
  }
  if (!Object.keys(toolCalls).length && !slots) return value;
  return {
    ...value,
    ...(slots ? { tools: slots } : {}),
    ...(Object.keys(toolCalls).length ? { toolCalls } : {}),
  };
}
