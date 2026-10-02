import { isDeepStrictEqual } from "node:util";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Conversation, Harness, DocumentWatch } from "@earendil-works/pi-durable";
import {
  DurableUI,
  MAX_DURABLE_UI_REQUESTS,
  MAX_DURABLE_UI_NOTIFICATION_SLOTS,
  sanitizeUIRequest,
  sanitizeUINotification,
  type UIResponse,
  type UIState,
} from "../extensions/durable/durable-ui.js";
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
    // Never retain the raw document as projection state. Limit traversal before
    // materializing entries and retain only the allowlisted, bounded snapshot.
    const current: UIState = { requests: Object.create(null), notifications: Object.create(null) };
    let count = 0;
    let overflow = false;
    for (const id in value?.requests) {
      if (!Object.hasOwn(value.requests, id)) continue;
      if (++count > MAX_DURABLE_UI_REQUESTS) {
        overflow = true;
        break;
      }
      const entry = value.requests[id];
      const request = sanitizeUIRequest(id, entry?.request);
      if (request && entry)
        current.requests[id] = { taskId: entry.taskId, request, response: entry.response };
    }
    count = 0;
    if (!overflow)
      for (const slot in value?.notifications) {
        if (!Object.hasOwn(value.notifications, slot)) continue;
        if (++count > MAX_DURABLE_UI_NOTIFICATION_SLOTS) {
          overflow = true;
          break;
        }
        const notification = sanitizeUINotification(slot, value.notifications[slot]);
        if (notification) current.notifications[slot] = notification;
      }
    if (overflow)
      this.emit({ type: "prompt_error", error: "Durable extension UI slot limit exceeded" });
    for (const [id, entry] of Object.entries(this.previous.requests)) {
      if (
        !entry.response &&
        (!current.requests[id] ||
          current.requests[id].response ||
          !isDeepStrictEqual(entry.request, current.requests[id].request))
      ) {
        this.emit({ type: "extension_ui_request_settled", id });
        clearTimeout(this.timers.get(id));
        this.timers.delete(id);
      }
    }
    for (const [id, entry] of Object.entries(current.requests)) {
      if (
        entry.response ||
        (this.previous.requests[id] &&
          !this.previous.requests[id].response &&
          isDeepStrictEqual(this.previous.requests[id].request, entry.request))
      )
        continue;
      this.emit({ ...entry.request, type: "extension_ui_request" });
      if (typeof entry.request.timeoutAt === "number" && Number.isFinite(entry.request.timeoutAt)) {
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
        this.emit({ ...notification, type: "extension_ui_request" });
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
