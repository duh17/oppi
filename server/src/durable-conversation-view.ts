/**
 * Client projection of a durable conversation for the conversation stream:
 * which documents clients replicate, the fields entries and `pi.live` carry (tool presentation
 * included), and the queue `pi.inbox` shows. Pure functions over committed values and decided
 * presentation; the room in `durable-conversation-stream.ts` owns state and delivery.
 */
import type { Message } from "@earendil-works/pi-ai";
import {
  AgentDoc,
  InboxDoc,
  LiveDoc,
  UsageDoc,
  type ConversationDocToken,
  type EntryRecord,
  type InboxState,
  type JsonObject,
  type LiveState,
  type ToolSlot,
} from "@earendil-works/pi-durable";
import type { JsonValue } from "@earendil-works/chord";
import { DurableUIClientDoc, sanitizeTranscriptCard } from "../extensions/durable/durable-ui.js";
import { agentMessageOrigin } from "../extensions/durable/sessions/agent-message.js";
import { normalizeAudioPresentationDetails } from "./audio-presentation.js";
import { resolveToolDisplay, type MobileRendererRegistry } from "./mobile-renderer.js";
import { storeUserMessageImages } from "./session-attachments.js";
import { resolveToolArguments } from "./tool-call-arguments.js";
import type {
  ConversationEntryCard,
  ConversationEntryView,
  ConversationMessageView,
  ConversationQueueView,
  ConversationToolCallView,
  ConversationToolResultView,
  MessageQueueItem,
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
  /** Part of the live tail: also sent to a `live` mode attach, which gets no entries. */
  readonly live?: true;
  readonly view?: (value: T, presenter: DocPresenter) => object;
}

/** Tool presentation shared by entry views and the live view. */
export interface ToolPresenter {
  call(name: string, args: unknown): ConversationToolCallView;
  /** Name and arguments of a committed tool call in the active entries. */
  committedCall(callId: string): { name: string; args: unknown } | undefined;
}

/**
 * Presentation a document view reads: tools, and how the queue shows each queued input.
 * The room decides queued inputs in its presentation passes (`readQueuedInput`, input-card
 * receipts), since both depend on state outside `pi.inbox`.
 */
export interface DocPresenter extends ToolPresenter {
  /** The queue item for submission `id`; undefined for an extension-generated input. */
  queuedInput(id: number): MessageQueueItem | undefined;
}

/** A client document with its value type erased, for iteration. */
export interface ClientDocSpec {
  readonly kind: string;
  readonly live: boolean;
  readonly doc: ConversationDocToken<JsonObject>;
  project(value: JsonObject, presenter: DocPresenter): JsonObject;
}

function clientDoc<T extends JsonObject>(spec: ClientDoc<T>): ClientDocSpec {
  const view = spec.view;
  return {
    kind: spec.doc.definition.kind,
    live: spec.live === true,
    doc: spec.doc as unknown as ConversationDocToken<JsonObject>,
    project: (value, presenter) => (view ? view(value as T, presenter) : value) as JsonObject,
  };
}

/**
 * The documents clients replicate. Pi built-ins Oppi shows (`pi.provider` stays
 * private), then extension documents that declare themselves client-visible.
 */
export const CONVERSATION_CLIENT_DOCS: readonly ClientDocSpec[] = [
  clientDoc({
    doc: LiveDoc,
    client: true,
    live: true,
    view: (value, presenter) => liveView(value, presenter, liveProjection),
  }),
  clientDoc({ doc: InboxDoc, client: true, live: true, view: queueView }),
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
    calls.push({ id: record.id, name: record.name, args: resolveToolArguments(record) });
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
 * Message fields clients read, by role (`ConversationTraceProjector` and
 * `ConversationLiveTail` in the Apple client). The rest stays on the server: provider
 * replay state (request controls), provider diagnostics (input transformations), usage,
 * timing, and system prompt sections. Providers may add any field, and some grow with
 * the transcript; in one long session they were over a third of a snapshot. Roles not
 * listed arrive whole.
 */
const CLIENT_MESSAGE_FIELDS = new Map<string, readonly string[]>([
  ["user", ["role", "content", "timestamp"]],
  // `stopReason` and `errorMessage` are small and say why an answer ended.
  ["assistant", ["role", "content", "timestamp", "stopReason", "errorMessage"]],
  ["toolResult", ["role", "content", "timestamp", "toolCallId", "toolName", "isError", "details"]],
  // Clients show nothing for system messages; their sections are the whole system prompt.
  ["system", ["role", "timestamp"]],
]);

/**
 * Content block fields clients read, by block type. Thinking and text signatures are
 * provider replay state. A tool call's arguments are resolved here from `arguments` and
 * `partialJson`, so clients get one answer and never the raw stream text. Block types not
 * listed (audio) arrive whole. A user message's image block leaves as either its bytes or,
 * once stored, a reference (`attachment`) to them.
 */
const CLIENT_BLOCK_FIELDS = new Map<string, readonly string[]>([
  ["text", ["type", "text"]],
  ["thinking", ["type", "thinking"]],
  ["toolCall", ["type", "id", "name", "arguments"]],
  ["image", ["type", "data", "mimeType", "attachment"]],
]);

/** Where a user message's image bytes are stored: the session's attachment store. */
export interface UserImageStoreScope {
  dataDir: string;
  sessionId: string;
}

function pick(source: Record<string, unknown>, fields: readonly string[]): Record<string, unknown> {
  const picked: Record<string, unknown> = {};
  for (const field of fields) if (source[field] !== undefined) picked[field] = source[field];
  return picked;
}

/** `block` with only the fields clients read (`CLIENT_BLOCK_FIELDS`). */
function projectBlock(block: unknown, attachment?: Record<string, unknown>): unknown {
  const record = asRecord(block);
  if (record && attachment) {
    // A stored user image: the client renders it from the session attachment route.
    return {
      type: "image",
      ...(typeof record.mimeType === "string" ? { mimeType: record.mimeType } : {}),
      attachment,
    };
  }
  const fields = typeof record?.type === "string" && CLIENT_BLOCK_FIELDS.get(record.type);
  if (!record || !fields) return block;
  const view = pick(record, fields);
  if (record.type !== "toolCall") return view;
  const args = resolveToolArguments(record);
  if (args === undefined) delete view.arguments;
  else view.arguments = args;
  return view;
}

/** Projects one content block; the live tail passes a cached one (see `LiveProjection`). */
type BlockProjector = (block: unknown, attachment?: Record<string, unknown>) => unknown;

/** `message` with only the fields clients read (`CLIENT_MESSAGE_FIELDS`). */
function projectMessage(
  message: Message,
  images?: UserImageStoreScope,
  project: BlockProjector = projectBlock,
): ConversationMessageView {
  const record = message as unknown as ConversationMessageView;
  const fields = CLIENT_MESSAGE_FIELDS.get(record.role);
  if (!fields) return record;
  const view = pick(record, fields) as ConversationMessageView;
  if (!Array.isArray(view.content)) return view;
  // A user message's images move into the session attachment store at projection time, so
  // the stream carries a reference and never the bytes (the model still gets them).
  const storedByIndex =
    record.role === "user" && images
      ? new Map(
          storeUserMessageImages({
            dataDir: images.dataDir,
            sessionId: images.sessionId,
            content: view.content,
          }).map((stored) => [stored.blockIndex, stored.details]),
        )
      : undefined;
  view.content = view.content.map((block, index) => project(block, storedByIndex?.get(index)));
  return view;
}

/**
 * Identity-preserving projection of `pi.live` (`liveView`).
 *
 * A document goes out as `diffRevisions(previous, next)` and skips any subtree whose values
 * are `===`, so a source block the commit did not touch must project to the identical object;
 * otherwise every 100 ms frame would resend the whole answer instead of its new text.
 * pi-durable revisions share structure (only the changed path is copied per commit), so a
 * WeakMap keyed by the source block, message, and generation restores that sharing on the
 * projected side. Keys are the committed values; nothing here keeps them alive.
 */
class LiveProjection {
  private readonly blocks = new WeakMap<object, object>();
  private readonly messages = new WeakMap<object, ConversationMessageView>();
  private readonly generations = new WeakMap<object, object>();

  block(block: unknown): unknown {
    if (typeof block !== "object" || block === null) return block;
    const cached = this.blocks.get(block);
    if (cached) return cached;
    const view = projectBlock(block) as object;
    this.blocks.set(block, view);
    return view;
  }

  message(message: Message): ConversationMessageView {
    const cached = this.messages.get(message);
    if (cached) return cached;
    const view = projectMessage(message, undefined, (block) => this.block(block));
    this.messages.set(message, view);
    return view;
  }

  /** `generation` with its committed partial projected like an entry's message. */
  generation(generation: object): object {
    const cached = this.generations.get(generation);
    if (cached) return cached;
    const source = generation as { message?: unknown };
    const message = asRecord(source.message);
    const view = message
      ? { ...source, message: this.message(source.message as Message) }
      : { ...source };
    this.generations.set(generation, view);
    return view;
  }
}

/**
 * `EntryRecord` without storage internals, plus the presentation trace history gives it
 * (`projectEntries` in `durable-history.ts`): tool rendering, cards, and hiding. Model
 * messages carry only the fields clients read (`projectMessage`).
 */
export function projectEntry(
  entry: EntryRecord,
  renderers: MobileRendererRegistry,
  tools: ToolPresenter,
  presentation: EntryPresentation = {},
  images?: UserImageStoreScope,
): ConversationEntryView {
  const view: ConversationEntryView = { id: entry.id, kind: entry.kind };
  if (presentation.hidden) return { ...view, hidden: true };
  // Like the trace, an extension-generated input shows only its card, never the raw input.
  if (presentation.inputCard) return { ...view, card: presentation.inputCard, inputCard: true };
  if (entry.model) {
    const model: ConversationMessageView[] = [];
    for (const message of entry.model) {
      const projected = projectMessage(message, images);
      model.push(projected);
      if (message.role !== "toolResult") continue;
      // Trace history normalizes audio and strips server-private paths at the client
      // boundary; so does the stream.
      const raw =
        message.details === undefined
          ? undefined
          : normalizeAudioPresentationDetails(message.details);
      const details = raw === undefined ? undefined : sanitizeToolResultDetails(raw).details;
      if (details !== undefined) projected.details = details;
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
  // Clients get only what trace history derives from it: an agent message's validated
  // origin, and a sanitized card.
  const agentMessage = agentMessageOrigin(entry.kind, entry.data);
  if (agentMessage) {
    view.origin = agentMessage.origin;
    if (agentMessage.textOffset) view.textOffset = agentMessage.textOffset;
  }
  if (!entry.model?.length) {
    const data = asRecord(entry.data);
    const card = sanitizeTranscriptCard(data?.card);
    if (card) view.card = card;
  }
  return view;
}

/**
 * `pi.inbox` as the queue shows it: the queued user inputs the presenter decided, steers and
 * follow-ups in inbox order. Writes and generated inputs stay out, and model content (image
 * data included) never leaves the server.
 */
function queueView(value: InboxState, presenter: DocPresenter): ConversationQueueView {
  const queue: ConversationQueueView = { steering: [], followUp: [] };
  for (const item of value.items) {
    if (item.mode === "write") continue;
    const shown = presenter.queuedInput(item.id);
    if (shown) queue[item.mode === "steer" ? "steering" : "followUp"].push(shown);
  }
  return queue;
}

/**
 * `pi.live` plus `toolCalls`: presentation by call id for the streaming answer's tool
 * calls and the running tool round. Slot `details` are sanitized like results.
 */
function liveView(value: LiveState, tools: ToolPresenter, live: LiveProjection): object {
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
  // Projected like an entry's messages, so provider replay state (signatures) and the raw
  // streaming `partialJson` stay on the server.
  const projected: object = value.generation
    ? { ...value, generation: live.generation(value.generation) }
    : value;
  if (!Object.keys(toolCalls).length && !slots) return projected;
  return {
    ...projected,
    ...(slots ? { tools: slots } : {}),
    ...(Object.keys(toolCalls).length ? { toolCalls } : {}),
  };
}

/** Shared by every room: the source values it keys on are the store's own revisions. */
const liveProjection = new LiveProjection();
