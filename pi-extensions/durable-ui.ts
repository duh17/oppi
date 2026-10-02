import type { Context, JsonValue } from "@earendil-works/chord";
import {
  defineDoc,
  type ToolExecutionApi,
  type TaskId,
} from "@earendil-works/pi-durable";

// Structural Pi/Oppi UI payloads. No classic factory or server runtime is loaded.
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
  if (saved) return saved;
  await api.commit(async (tx) => {
    const ui = await tx.doc(DurableUI, api.conversationId);
    ui.requests[request.id] ??= {
      taskId: api.taskId,
      request: {
        ...request,
        ...(request.timeout && request.timeoutAt === undefined
          ? { timeoutAt: Date.now() + request.timeout }
          : {}),
      },
    };
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
    await api.commit(async (tx) => {
      delete (await tx.doc(DurableUI, api.conversationId)).requests[request.id];
    }, context);
    return winner;
  } finally {
    removeAbortListener();
    await watch.stop();
  }
}
