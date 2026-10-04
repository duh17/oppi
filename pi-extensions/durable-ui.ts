import type { TranscriptCard } from "./transcript-card.js";
import type { Context, JsonValue } from "@earendil-works/chord";
import {
  defineDoc,
  type ToolExecutionApi,
  type TaskId,
} from "@earendil-works/pi-durable";

// Structural Pi/Oppi UI payloads. No classic factory or server runtime is loaded.
// Re-export the pure helper; classic trace imports it without loading Durable.
export {
  sanitizeTranscriptCard,
  type TranscriptCard,
} from "./transcript-card.js";

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
    | "setStatus"
    | "setWidget"
    | "setWorkingMessage"
    | "setWorkingIndicator"
    | "setWorkingVisible";
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
  requests: Record<
    string,
    { taskId: TaskId; request: UIRequest; response?: UIResponse }
  >;
  // Keys identify replacement slots, not extension identities. Keep explicit
  // empty notifications to clear previous client state (including after restart).
  notifications: Record<string, UINotification>;
};
/** Only protocol UI fields may cross the document → session-event boundary. */
export function sanitizeUIRequest(
  id: string,
  value: unknown,
): UIRequest | undefined {
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

export function sanitizeUINotification(
  id: string,
  value: unknown,
): UINotification | undefined {
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
    if (Object.hasOwn(data, field) && data[field] !== undefined)
      result[field] = data[field];
  return result;
}

export const DurableUI = defineDoc<UIState>({
  kind: "oppi.extension-ui",
  version: 1,
  scope: "conversation",
  history: "latest",
  fork: "initial",
  initial: () => ({ requests: {}, notifications: {} }),
});

/** Publish once per tool task; the answer survives a crash before the memo write. */
export async function requestUI(
  api: ToolExecutionApi,
  request: UIRequest,
  context: Context,
): Promise<UIResponse> {
  const memoKey = `ui-answer:${request.id}`;
  const saved = await api.memo<UIResponse>(memoKey, context);
  const remove = async (): Promise<void> => {
    await api.commit(async (tx) => {
      delete (await tx.doc(DurableUI, api.conversationId)).requests[request.id];
    }, context);
  };
  if (saved) {
    // Replay can land here after a crash between memo persistence and deletion.
    await remove();
    return saved;
  }
  const payload = sanitizeUIRequest(request.id, request);
  if (!payload) throw new Error("Unsupported durable UI request method");
  await api.commit(async (tx) => {
    const ui = await tx.doc(DurableUI, api.conversationId);
    const existing = ui.requests[request.id];
    if (existing && existing.taskId !== api.taskId)
      throw new Error("Durable UI request belongs to another task");
    // Replay keeps the committed request, answer, and original absolute deadline.
    if (existing) return;
    if (payload.timeout && payload.timeoutAt === undefined)
      payload.timeoutAt = Date.now() + payload.timeout;
    ui.requests[request.id] = { taskId: api.taskId, request: payload };
  }, context);
  const watch = await api.watchDoc(DurableUI, api.conversationId, context);
  if (!watch) throw new Error("Durable UI document disappeared");
  let removeAbortListener = (): void => {};
  try {
    const response = await new Promise<UIResponse>((resolve, reject) => {
      const signal = context.abortSignal;
      const abort = (): void =>
        reject(signal?.reason ?? new Error("UI wait aborted"));
      const take = (ui: UIState | null): void => {
        const entry = ui?.requests[request.id];
        if (entry?.response) {
          signal?.removeEventListener("abort", abort);
          resolve(entry.response);
        } else if (!entry) {
          signal?.removeEventListener("abort", abort);
          resolve({ id: request.id, cancelled: true });
        }
      };
      signal?.addEventListener("abort", abort, { once: true });
      removeAbortListener = () => signal?.removeEventListener("abort", abort);
      watch.start(async (ui) => take(ui));
      take(watch.value);
      if (signal?.aborted) abort();
    });
    const winner = await api.memo(memoKey, response, context);
    await remove();
    return winner;
  } finally {
    removeAbortListener();
    await watch.stop();
  }
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
});
