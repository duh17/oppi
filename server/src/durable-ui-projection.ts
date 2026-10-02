import { isDeepStrictEqual } from "node:util";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Conversation, Harness, DocumentWatch } from "@earendil-works/pi-durable";
import { DurableUI, type UIResponse, type UIState } from "../extensions/durable/durable-ui.js";
import type { SessionBackendEvent } from "./pi-events.js";

/** Committed documents → the same events as SdkUiBridge, through the shared sanitizer/state owner. */
export class DurableUIProjection {
  private previous: UIState = { requests: {}, notifications: {} };
  private readonly timers = new Map<string, ReturnType<typeof setTimeout>>();
  private stopped = false;
  private constructor(
    private readonly conversation: Conversation,
    private readonly watch: DocumentWatch<UIState>,
    private readonly emit: (event: SessionBackendEvent) => void,
  ) {}
  static async create(
    harness: Harness,
    conversation: Conversation,
    emit: (event: SessionBackendEvent) => void,
  ): Promise<DurableUIProjection> {
    await conversation.commit(async (tx) => {
      await tx.doc(DurableUI, conversation.id);
    }, BACKGROUND_CONTEXT);
    const watch = await harness.watchDoc(DurableUI, conversation.id, BACKGROUND_CONTEXT);
    if (!watch) throw new Error("Durable UI document is missing");
    return new DurableUIProjection(conversation, watch, emit);
  }
  start(): void {
    this.apply(this.watch.value);
    this.watch.start(async (value) => {
      if (!this.stopped) this.apply(value);
    });
  }
  private apply(value: UIState | null): void {
    const current = value ?? { requests: {}, notifications: {} };
    for (const [id, entry] of Object.entries(this.previous.requests)) {
      if (!entry.response && (!current.requests[id] || current.requests[id].response)) {
        this.emit({ type: "extension_ui_request_settled", id });
        clearTimeout(this.timers.get(id));
        this.timers.delete(id);
      }
    }
    for (const [id, entry] of Object.entries(current.requests)) {
      if (entry.response || this.previous.requests[id]) continue;
      this.emit({ type: "extension_ui_request", ...entry.request });
      if (entry.request.timeoutAt !== undefined) {
        this.timers.set(
          id,
          setTimeout(
            () => {
              void this.respond({ id, cancelled: true }).catch((error: unknown) => {
                if (!this.stopped) this.emit({ type: "prompt_error", error: String(error) });
              });
            },
            Math.max(0, entry.request.timeoutAt - Date.now()),
          ),
        );
      }
    }
    for (const [slot, notification] of Object.entries(current.notifications)) {
      if (!isDeepStrictEqual(this.previous.notifications[slot], notification))
        this.emit({ type: "extension_ui_request", ...notification });
    }
    this.previous = current;
  }
  async respond(response: UIResponse): Promise<boolean> {
    if (this.stopped) return false;
    return this.conversation.commit(async (tx) => {
      const ui = await tx.doc(DurableUI, this.conversation.id);
      const entry = ui.requests[response.id];
      if (!entry || entry.response) return false;
      const task = await tx.task(entry.taskId);
      if (!task || task.abortRequested || task.state.status === "terminal") return false;
      // First committed answer wins. Never settle UI before persistence succeeds.
      entry.response = {
        id: response.id,
        ...(response.value === undefined ? {} : { value: response.value }),
        ...(response.confirmed === undefined ? {} : { confirmed: response.confirmed }),
        ...(response.cancelled === undefined ? {} : { cancelled: response.cancelled }),
      };
      return true;
    }, BACKGROUND_CONTEXT);
  }
  async stop(): Promise<void> {
    this.stopped = true;
    for (const timer of this.timers.values()) clearTimeout(timer);
    this.timers.clear();
    await this.watch.stop();
  }
}
