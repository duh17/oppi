import type { TranscriptCard } from "./transcript-card.js";
import { BACKGROUND_CONTEXT, type Context } from "@earendil-works/chord/context";
import type { JsonValue } from "@earendil-works/chord/json";
import { bool, obj, opt, str } from "@earendil-works/pi-schema";
import {
  defineDoc,
  defineSignal,
  type ConversationId,
  type Harness,
  type SignalResult,
  type ToolExecutionApi,
  type SignalKey,
  type TaskId,
  type Tx,
} from "@earendil-works/pi-durable";

// Structural Pi/Oppi UI payloads. No classic factory or server runtime is loaded.
// Re-export the pure helper; classic trace imports it without loading Durable.
export { sanitizeTranscriptCard, type TranscriptCard } from "./transcript-card.js";

export type UIRequest = {
  id: string;
  method: "ask" | "select" | "confirm" | "input" | "editor";
  title?: string;
  message?: string;
  options?: string[];
  placeholder?: string;
  prefill?: string;
  questions?: Array<{
    id: string;
    question: string;
    options: Array<{ value: string; label: string; description?: string }>;
    multiSelect?: boolean;
  }>;
  allowCustom?: boolean;
  timeout?: number;
  timeoutAt?: number;
  extensionScopeId?: string;
  extensionDisplayName?: string;
};
export type UIResponse = {
  id: string;
  value?: string;
  confirmed?: boolean;
  cancelled?: boolean;
};
export type UINotification = {
  id: string;
  method:
    "setStatus" | "setWidget" | "setWorkingMessage" | "setWorkingIndicator" | "setWorkingVisible";
  statusKey?: string;
  statusText?: string;
  widgetKey?: string;
  widgetLines?: string[];
  widgetPlacement?: "aboveEditor" | "belowEditor";
  nativeSurface?: { [key: string]: JsonValue };
  message?: string;
  workingIndicator?: { frames: string[]; intervalMs: number };
  workingVisible?: boolean;
  extensionScopeId?: string;
  extensionDisplayName?: string;
};
export type UIState = {
  /** Open requests only: an answer takes its request down in the commit that delivers it. */
  requests: Record<string, { taskId: TaskId; request: UIRequest }>;
  // Keys identify replacement slots, not extension identities. Keep explicit
  // empty notifications to clear previous client state (including after restart).
  notifications: Record<string, UINotification>;
  /**
   * When the owner last stopped this conversation's Session from a client, epoch ms. Stop also
   * dismisses: a parent's subagent pill keeps a failed child under Needs You until it is
   * messaged or stopped after the failure. An idle Session's own auto-stop does not write it.
   */
  stoppedAt?: number;
};
/** Only protocol UI fields may cross the document → session-event boundary. */
export function sanitizeUIRequest(id: string, value: unknown): UIRequest | undefined {
  if (!value || typeof value !== "object") return undefined;
  const data = value as Record<string, unknown>;
  const method = data.method;
  if (
    method !== "ask" &&
    method !== "select" &&
    method !== "confirm" &&
    method !== "input" &&
    method !== "editor"
  )
    return undefined;
  return {
    ...pickUIFields(data, [
      "title",
      "message",
      "options",
      "placeholder",
      "prefill",
      "questions",
      "allowCustom",
      "timeout",
      "timeoutAt",
      "extensionScopeId",
      "extensionDisplayName",
    ]),
    id,
    method,
  } as UIRequest;
}

export function sanitizeUINotification(id: string, value: unknown): UINotification | undefined {
  if (!value || typeof value !== "object") return undefined;
  const data = value as Record<string, unknown>;
  const method = data.method;
  if (
    method !== "setStatus" &&
    method !== "setWidget" &&
    method !== "setWorkingMessage" &&
    method !== "setWorkingIndicator" &&
    method !== "setWorkingVisible"
  )
    return undefined;
  return {
    ...pickUIFields(data, [
      "statusKey",
      "statusText",
      "widgetKey",
      "widgetLines",
      "widgetPlacement",
      "nativeSurface",
      "message",
      "workingIndicator",
      "workingVisible",
      "extensionScopeId",
      "extensionDisplayName",
    ]),
    id,
    method,
  } as UINotification;
}

function pickUIFields(
  data: Record<string, unknown>,
  fields: readonly string[],
): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const field of fields)
    if (Object.hasOwn(data, field) && data[field] !== undefined) result[field] = data[field];
  return result;
}

// Follows pi.live (pi-durable harness/live.ts, spec §3.5): store a complete base
// whenever no run is shown, so the stored chain spans at most one run and an idle
// conversation keeps no history. A run shows a working message; idle clears it.
// Unlike pi.live, a run's chain carries a once-per-second elapsed-time message,
// so a long run also stores a base every 500 deltas (warm replay is ~1.6 ms per
// 1,000). History is latest: the next write of an existing chain drops it.
const EXTENSION_UI_CHECKPOINT_DELTAS = 500;
const showsRun = (value: Readonly<UIState>): boolean =>
  Object.values(value.notifications).some(
    (notification) => notification.method === "setWorkingMessage" && !!notification.message,
  );

export const DurableUI = defineDoc<UIState>({
  kind: "oppi.extension-ui",
  version: 1,
  scope: "conversation",
  history: "latest",
  fork: "initial",
  initial: () => ({ requests: {}, notifications: {} }),
  checkpointWhen: (value, _ops, info) =>
    !showsRun(value) || info.deltasSinceBase >= EXTENSION_UI_CHECKPOINT_DELTAS,
});

/**
 * Conversation stream visibility: clients replicate the open requests and the
 * notification slots, allowlisted like the event projection. Task ids stay on
 * the server.
 */
export const DurableUIClientDoc = {
  doc: DurableUI,
  client: true,
  view(value: UIState): {
    requests: Record<string, UIRequest>;
    notifications: Record<string, UINotification>;
  } {
    const requests: Record<string, UIRequest> = Object.create(null);
    const notifications: Record<string, UINotification> = Object.create(null);
    for (const id in value.requests) {
      if (!Object.hasOwn(value.requests, id)) continue;
      const request = sanitizeUIRequest(id, value.requests[id]?.request);
      if (request) requests[id] = request;
    }
    for (const slot in value.notifications) {
      if (!Object.hasOwn(value.notifications, slot)) continue;
      const notification = sanitizeUINotification(slot, value.notifications[slot]);
      if (notification) notifications[slot] = notification;
    }
    return { requests, notifications };
  },
} as const;

/**
 * Records that the owner stopped a conversation's Session from a client (`stoppedAt`). A parent's
 * subagent pill reads it: Stop also dismisses a failed child.
 */
export async function recordOwnerStop(harness: Harness, id: ConversationId): Promise<void> {
  const conversation = await harness.conversation(id, BACKGROUND_CONTEXT);
  await conversation?.commit(async (tx) => {
    (await tx.doc(DurableUI, id)).stoppedAt = Date.now();
  }, BACKGROUND_CONTEXT);
}

/**
 * The answer to one request, delivered to the asking call's task under the request id. pi-durable
 * keeps it in the task until the task ends, so a rerun after a crash reads the same answer.
 */
export const UIAnswer = defineSignal({
  name: "oppi.ui-answer",
  version: 1,
  schema: obj({ id: str(), value: opt(str()), confirmed: opt(bool()), cancelled: opt(bool()) }),
});

/**
 * The park `requestUI` returns: a tool returns it from `execute()` as is, a `beforeTool` hook
 * returns its `sleep` (`{ sleep: park.sleep }`).
 */
export type UIPark = {
  readonly sleep: {
    readonly checkpoint: { ui: string };
    readonly signals: readonly SignalKey<unknown>[];
    readonly until?: number;
  };
};

/** What `requestUI` gives its caller: the answer, or the park to wait in until one comes. */
export type UIOutcome =
  { response: UIResponse; park?: undefined } | { park: UIPark; response?: undefined };

/**
 * Ask through the app from a replay-safe tool. The first run publishes the request and returns a
 * park: the tool returns it from `execute()`, and the call holds no process until the answer (or
 * the request's `timeoutAt`) wakes it; a restart meanwhile runs no tool code. The woken run calls
 * `requestUI` again with the same request and gets the answer; a deadline that came first answers
 * `cancelled`. Give the tool `cancel: withdrawUI`, so a stopped call takes its request down.
 * A `beforeTool` hook passes its runtime as `api` and returns `{ sleep: park.sleep }`; every wake
 * runs it again, so it reaches the answer the same way.
 */
export async function requestUI(
  api: ToolExecutionApi,
  request: UIRequest,
  context: Context,
): Promise<UIOutcome> {
  const payload = sanitizeUIRequest(request.id, request);
  if (!payload) throw new Error("Unsupported durable UI request method");
  const state = await api.readSignal(UIAnswer, request.id, context);
  if (state !== undefined) {
    // An answer took the request down when it was delivered; an expired deadline did not, nor did
    // an answer that arrived before the request went up (Oppi Control's Apply All).
    if ((await api.snapshot(DurableUI, api.conversationId, context))?.requests[request.id])
      await api.commit(async (tx) => {
        delete (await tx.doc(DurableUI, api.conversationId)).requests[request.id];
      }, context);
    return { response: "value" in state ? state.value : { id: request.id, cancelled: true } };
  }
  const timeoutAt = await api.commit(async (tx) => {
    const ui = await tx.doc(DurableUI, api.conversationId);
    const existing = ui.requests[request.id];
    if (existing && existing.taskId !== api.taskId)
      throw new Error("Durable UI request belongs to another task");
    // A rerun that never parked keeps the committed request and its original absolute deadline.
    if (existing) return existing.request.timeoutAt;
    if (payload.timeout && payload.timeoutAt === undefined)
      payload.timeoutAt = api.now() + payload.timeout;
    ui.requests[request.id] = { taskId: api.taskId, request: payload };
    return payload.timeoutAt;
  }, context);
  return {
    park: {
      sleep: {
        checkpoint: { ui: request.id },
        signals: [UIAnswer.key(request.id)],
        ...(timeoutAt === undefined ? {} : { until: timeoutAt }),
      },
    },
  };
}

/** A tool's `cancel` for a call parked by `requestUI`: takes the call's open request down. */
export async function withdrawUI(
  _args: unknown,
  api: ToolExecutionApi,
  context: Context,
): Promise<void> {
  const id = (api.checkpoint as { ui?: unknown } | undefined)?.ui;
  if (typeof id !== "string") return;
  await api.commit(async (tx) => {
    delete (await tx.doc(DurableUI, api.conversationId)).requests[id];
  }, context);
}

/**
 * Deliver each answer to its call's task and take its request down, in the caller's commit. A
 * request whose call already has an answer, ended, or was stopped (`duplicate`, `closed`,
 * `not_found`) is taken down too: nothing can answer it any more, as when a gate's call was
 * aborted (a gate has no `cancel`). Only an `invalid` answer leaves the request up. Every delivery
 * starts before any lands: a delivery stages its task, and a `Tx` refuses reads after a write.
 */
export async function answerUI(
  tx: Tx,
  conversationId: ConversationId,
  answers: ReadonlyArray<{ taskId: TaskId; response: UIResponse }>,
): Promise<SignalResult[]> {
  const ui = await tx.doc(DurableUI, conversationId);
  const results = await Promise.all(
    answers.map(({ taskId, response }) =>
      tx.signal(taskId, UIAnswer, response.id, {
        id: response.id,
        ...(response.value === undefined ? {} : { value: response.value }),
        ...(response.confirmed === undefined ? {} : { confirmed: response.confirmed }),
        ...(response.cancelled === undefined ? {} : { cancelled: response.cancelled }),
      }),
    ),
  );
  answers.forEach(({ response }, index) => {
    if (results[index] !== "invalid") delete ui.requests[response.id];
  });
  return results;
}

/**
 * Stop's sweep: every open request of the conversation answered `cancelled` and taken down, in the
 * caller's commit. Stop aborts the calls first, so their deliveries are `closed`; a call Stop did
 * not abort wakes with `cancelled` instead of sleeping on a card nobody can see.
 */
export async function cancelAllUI(tx: Tx, conversationId: ConversationId): Promise<void> {
  const ui = await tx.doc(DurableUI, conversationId);
  await answerUI(
    tx,
    conversationId,
    Object.entries(ui.requests).map(([id, { taskId }]) => ({
      taskId,
      response: { id, cancelled: true },
    })),
  );
  ui.requests = {};
}

/** Display metadata for extension-generated inputs, keyed by stable submission
 * request ID. Publish BEFORE submit so live projection cannot expose raw input
 * while waiting for metadata. Model content and admission remain Harness-owned.
 * This is not an extension-name or message-text rendering convention.
 */
export const DurableInputCards = defineDoc<{
  requests: Record<string, TranscriptCard>;
}>({
  kind: "oppi.input-cards",
  version: 1,
  scope: "conversation",
  history: "latest",
  fork: "initial",
  initial: () => ({ requests: {} }),
  // Written for every extension-generated input; a base bounds its replay.
  checkpointWhen: (_value, _ops, { deltasSinceBase }) => deltasSinceBase >= 64,
});
