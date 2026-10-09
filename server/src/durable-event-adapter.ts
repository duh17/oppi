// Maps committed Durable events into the existing Pi session projection pipeline.
// Durable backoff and compaction receipts need batch-level correlation before Pi projection.
import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import {
  UserEntry,
  type AgentEvent,
  type EntryRecord,
  type MessageChange,
  type SnapshotEvent,
} from "@earendil-works/pi-durable";
import type { AssistantMessage, AssistantMessageEvent, Usage } from "@earendil-works/pi-ai";

const ZERO_USAGE: Usage = {
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};

export interface AdapterState {
  partial?: AssistantMessage;
  toolOutputs: Map<string, string>;
  toolArgs: Map<string, Record<string, unknown>>;
  toolDetails: Map<string, unknown>;
}

export function createAdapterState(): AdapterState {
  return {
    toolOutputs: new Map(),
    toolArgs: new Map(),
    toolDetails: new Map(),
  };
}

/**
 * Newest assistant written after the latest `pi.user` entry.
 * Compaction summaries and reset handoffs are user-role but not a new turn.
 * An assistant older than that user entry belongs to a finished turn.
 */
export function newestAssistantOfActiveRun(
  entries: readonly EntryRecord[],
): AssistantMessage | undefined {
  let lastUserId = -1;
  let newest: { id: number; message: AssistantMessage } | undefined;
  for (const entry of entries) {
    const message = entry.model?.[0];
    if (UserEntry.is(entry) && entry.id > lastUserId) lastUserId = entry.id;
    if (message?.role === "assistant" && (!newest || entry.id > newest.id)) {
      newest = { id: entry.id, message };
    }
  }
  if (!newest || newest.id < lastUserId) return undefined;
  return newest.message;
}

/** Re-bind a live turn without inventing another user input. */
export function snapshotEvents(snapshot: SnapshotEvent, state: AdapterState): AgentSessionEvent[] {
  state.partial = undefined;
  state.toolArgs.clear();
  state.toolOutputs.clear();
  state.toolDetails.clear();
  const events: AgentSessionEvent[] = [];
  if (snapshot.run) events.push(asPi({ type: "agent_start" }));
  if (snapshot.generation?.message) {
    events.push(
      ...adaptDurableEvent({ type: "message_start", message: snapshot.generation.message }, state),
    );
  }
  for (const slot of snapshot.tools) {
    if (slot.status === "done") continue;
    events.push(
      ...adaptDurableEvent(
        { type: "tool_execution_start", toolCallId: slot.callId, toolName: slot.name, args: {} },
        state,
      ),
    );
    events.push(
      ...adaptDurableEvent(
        {
          type: "tool_execution_update",
          toolCallId: slot.callId,
          toolName: slot.name,
          output: { set: slot.output ?? "" },
          details: slot.details,
        },
        state,
      ),
    );
  }
  return events;
}

export function adaptDurableEvent(
  event: AgentEvent,
  state: AdapterState,
  /** Ending run's newest assistant, read from committed entries at run_end. */
  runAssistant?: AssistantMessage,
): AgentSessionEvent[] {
  switch (event.type) {
    case "snapshot":
      return snapshotEvents(event, state);
    case "run_start":
      return [asPi({ type: "agent_start" })];
    case "run_end": {
      // Durable run_end has no Pi message list. The caller supplies the ending
      // run's assistant so SessionEventProcessor records turn_error on the SDK path.
      const errored = runAssistant?.stopReason === "error" ? [runAssistant] : [];
      return [
        asPi({ type: "agent_end", messages: errored, willRetry: false }),
        asPi({ type: "agent_settled" }),
      ];
    }
    case "turn_start":
      return [asPi({ type: "turn_start" })];
    case "turn_end":
      return [
        asPi({
          type: "turn_end",
          message: state.partial ?? dummyAssistant(),
          toolResults: [],
        }),
      ];
    case "message_start": {
      const started: AgentSessionEvent[] = [
        asPi({ type: "message_start", message: event.message }),
      ];
      // Durable's first partial already has content; Pi's message_start is empty then deltas.
      if (event.message.role === "assistant") {
        const assistant = event.message;
        state.partial = assistant;
        for (const assistantMessageEvent of expandMessageReplace(undefined, assistant)) {
          started.push(
            asPi({
              type: "message_update",
              message: assistant,
              assistantMessageEvent,
            }),
          );
        }
      }
      return started;
    }
    case "message_update":
      return adaptMessageUpdate(event, state);
    case "message_end": {
      const message = event.entry.model?.[0];
      if (!message) return [];
      if (message.role === "assistant") state.partial = undefined;
      return [asPi({ type: "message_end", message, entryId: String(event.entry.id) })];
    }
    case "tool_execution_start":
      state.toolArgs.set(event.toolCallId, event.args);
      state.toolOutputs.set(event.toolCallId, "");
      return [
        asPi({
          type: "tool_execution_start",
          toolCallId: event.toolCallId,
          toolName: event.toolName,
          args: event.args,
        }),
      ];
    case "tool_execution_update":
      return adaptToolUpdate(event, state);
    case "tool_execution_end":
      return adaptToolEnd(event, state);
    case "compaction_start":
      return [asPi({ type: "compaction_start", reason: event.reason })];
    // These are resolved by DurableEventProjection using task receipts and the whole batch.
    case "compaction_end":
    case "auto_retry_start":
    case "auto_retry_end":
      return [];
    default:
      return [];
  }
}

function adaptMessageUpdate(
  event: Extract<AgentEvent, { type: "message_update" }>,
  state: AdapterState,
): AgentSessionEvent[] {
  const out: AgentSessionEvent[] = [];
  for (const change of event.changes) {
    const prev = state.partial;
    state.partial = applyChange(state.partial, change, event.usage);
    const assistantEvents =
      change.type === "message"
        ? expandMessageReplace(prev, state.partial)
        : projectChange(prev, state.partial, change);
    for (const assistantMessageEvent of assistantEvents) {
      if (!assistantMessageEvent) continue;
      out.push(
        asPi({
          type: "message_update",
          message: state.partial,
          assistantMessageEvent,
        }),
      );
    }
  }
  return out;
}

function adaptToolUpdate(
  event: Extract<AgentEvent, { type: "tool_execution_update" }>,
  state: AdapterState,
): AgentSessionEvent[] {
  if (event.output) {
    const prev = state.toolOutputs.get(event.toolCallId) ?? "";
    state.toolOutputs.set(event.toolCallId, applyToolOutput(prev, event.output));
  }
  if (event.details !== undefined) {
    state.toolDetails.set(event.toolCallId, event.details);
  }
  const full = state.toolOutputs.get(event.toolCallId) ?? "";
  const details = state.toolDetails.get(event.toolCallId);
  return [
    asPi({
      type: "tool_execution_update",
      toolCallId: event.toolCallId,
      toolName: event.toolName,
      args: state.toolArgs.get(event.toolCallId) ?? {},
      partialResult: {
        content: full.length > 0 ? [{ type: "text", text: full }] : [],
        ...(details !== undefined && details !== null ? { details } : {}),
      },
    }),
  ];
}

function adaptToolEnd(
  event: Extract<AgentEvent, { type: "tool_execution_end" }>,
  state: AdapterState,
): AgentSessionEvent[] {
  const message = event.entry?.model?.[0];
  const args = state.toolArgs.get(event.toolCallId) ?? {};
  state.toolOutputs.delete(event.toolCallId);
  state.toolArgs.delete(event.toolCallId);
  state.toolDetails.delete(event.toolCallId);
  if (message?.role === "toolResult") {
    return [
      asPi({
        type: "tool_execution_end",
        toolCallId: event.toolCallId,
        toolName: event.toolName,
        args,
        result: { content: message.content, details: message.details },
        isError: message.isError === true,
      }),
    ];
  }
  return [
    asPi({
      type: "tool_execution_end",
      toolCallId: event.toolCallId,
      toolName: event.toolName,
      args,
      result: { content: [{ type: "text", text: "" }], details: {} },
      isError: true,
    }),
  ];
}

function applyChange(
  partial: AssistantMessage | undefined,
  change: MessageChange,
  usage: Usage,
): AssistantMessage {
  if (change.type === "message") return { ...change.message, usage };
  const base = partial ?? dummyAssistant(usage);
  const content = [...base.content];
  switch (change.type) {
    case "text_start":
    case "thinking_start":
    case "toolcall_start":
      content[change.contentIndex] = change.block;
      break;
    case "text_delta": {
      const block = content[change.contentIndex];
      if (block?.type === "text") {
        content[change.contentIndex] = { ...block, text: block.text + change.delta };
      }
      break;
    }
    case "thinking_delta": {
      const block = content[change.contentIndex];
      if (block?.type === "thinking") {
        content[change.contentIndex] = { ...block, thinking: block.thinking + change.delta };
      }
      break;
    }
    case "toolcall_delta": {
      const block = content[change.contentIndex];
      if (block?.type === "toolCall") {
        content[change.contentIndex] = {
          ...block,
          arguments: applyPathAppend(
            block.arguments,
            change.path,
            change.delta,
          ) as typeof block.arguments,
        };
      }
      break;
    }
    case "block":
      content[change.contentIndex] = change.block;
      break;
  }
  return { ...base, content, usage };
}

/** Durable may replace the whole partial in one throttled commit (`changes: [{type:"message"}]`). */
function expandMessageReplace(
  prev: AssistantMessage | undefined,
  next: AssistantMessage,
): AssistantMessageEvent[] {
  const events: AssistantMessageEvent[] = [];
  for (const [contentIndex, block] of next.content.entries()) {
    const old = prev?.content[contentIndex];
    if (block.type === "text") {
      const oldText = old?.type === "text" ? old.text : "";
      if (old?.type !== "text") {
        events.push({ type: "text_start", contentIndex, partial: next });
      }
      const projected = contentDelta(oldText, block.text);
      if (projected) {
        events.push({
          type: "text_delta",
          contentIndex,
          delta: projected.delta,
          partial: next,
          ...(projected.replace ? { replace: true } : {}),
        } as AssistantMessageEvent);
      }
    } else if (block.type === "thinking") {
      const oldText = old?.type === "thinking" ? old.thinking : "";
      if (old?.type !== "thinking") {
        events.push({ type: "thinking_start", contentIndex, partial: next });
      }
      const projected = contentDelta(oldText, block.thinking);
      if (projected) {
        events.push({
          type: "thinking_delta",
          contentIndex,
          delta: projected.delta,
          partial: next,
          ...(projected.replace ? { replace: true } : {}),
        } as AssistantMessageEvent);
      }
    } else if (block.type === "toolCall") {
      if (old?.type !== "toolCall") {
        events.push({ type: "toolcall_start", contentIndex, partial: next });
      }
      events.push({ type: "toolcall_end", contentIndex, toolCall: block, partial: next });
    }
  }
  return events;
}

/** Prefix growth stays a suffix delta. A rewrite carries the whole current partial and `replace`. */
function contentDelta(
  previous: string,
  next: string,
): { delta: string; replace?: true } | undefined {
  if (next === previous) return undefined;
  if (next.startsWith(previous)) {
    const delta = next.slice(previous.length);
    return delta ? { delta } : undefined;
  }
  return { delta: next, replace: true };
}

/** A completed text or thinking block is the current partial, not an ignored text_end. */
function projectChange(
  prev: AssistantMessage | undefined,
  next: AssistantMessage,
  change: MessageChange,
): AssistantMessageEvent[] {
  if (change.type !== "block") {
    const event = toAssistantMessageEvent(change, next);
    return event ? [event] : [];
  }
  const block = change.block;
  const old = prev?.content[change.contentIndex];
  if (block.type === "text" || block.type === "thinking") {
    const oldText =
      block.type === "text"
        ? old?.type === "text"
          ? old.text
          : ""
        : old?.type === "thinking"
          ? old.thinking
          : "";
    const projected = contentDelta(oldText, block.type === "text" ? block.text : block.thinking);
    if (!projected) return [];
    return [
      {
        type: block.type === "text" ? "text_delta" : "thinking_delta",
        contentIndex: change.contentIndex,
        delta: projected.delta,
        partial: next,
        ...(projected.replace ? { replace: true } : {}),
      } as AssistantMessageEvent,
    ];
  }
  const event = toAssistantMessageEvent(change, next);
  return event ? [event] : [];
}

function toAssistantMessageEvent(
  change: MessageChange,
  partial: AssistantMessage,
): AssistantMessageEvent | undefined {
  switch (change.type) {
    case "text_start":
      return { type: "text_start", contentIndex: change.contentIndex, partial };
    case "thinking_start":
      return { type: "thinking_start", contentIndex: change.contentIndex, partial };
    case "toolcall_start":
      return { type: "toolcall_start", contentIndex: change.contentIndex, partial };
    case "text_delta":
      return {
        type: "text_delta",
        contentIndex: change.contentIndex,
        delta: change.delta,
        partial,
      };
    case "thinking_delta":
      return {
        type: "thinking_delta",
        contentIndex: change.contentIndex,
        delta: change.delta,
        partial,
      };
    case "toolcall_delta":
      return {
        type: "toolcall_delta",
        contentIndex: change.contentIndex,
        delta: change.delta,
        partial,
      };
    case "block": {
      const block = change.block;
      // Text and thinking completion is projected in projectChange. text_end is not a ServerMessage.
      if (block.type === "toolCall") {
        return {
          type: "toolcall_end",
          contentIndex: change.contentIndex,
          toolCall: block,
          partial,
        };
      }
      return undefined;
    }
    case "message":
      return undefined;
  }
}

function applyToolOutput(
  prev: string,
  output: { trimStart?: number; append?: string } | { set: string },
): string {
  if ("set" in output) return output.set;
  return prev.slice(output.trimStart ?? 0) + (output.append ?? "");
}

function applyPathAppend(
  target: unknown,
  path: readonly (string | number)[],
  delta: string,
): unknown {
  if (path.length === 0) {
    return typeof target === "string" ? target + delta : delta;
  }
  const [head, ...rest] = path;
  if (head === undefined) return target;
  if (typeof head === "number") {
    const arr = Array.isArray(target) ? [...target] : [];
    arr[head] = applyPathAppend(arr[head], rest, delta);
    return arr;
  }
  const obj =
    target && typeof target === "object" && !Array.isArray(target)
      ? { ...(target as Record<string, unknown>) }
      : {};
  obj[head] = applyPathAppend(obj[head], rest, delta);
  return obj;
}

function dummyAssistant(usage: Usage = ZERO_USAGE): AssistantMessage {
  return {
    role: "assistant",
    content: [],
    api: "anthropic-messages",
    provider: "faux",
    model: "faux-1",
    usage,
    stopReason: "stop",
    timestamp: Date.now(),
  };
}

function asPi(event: object): AgentSessionEvent {
  return event as AgentSessionEvent;
}
