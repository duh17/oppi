import { isDeepStrictEqual } from "node:util";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Conversation, Harness, DocumentWatch } from "@earendil-works/pi-durable";
import {
  answerUI,
  DurableUI,
  sanitizeUIRequest,
  sanitizeUINotification,
  type UIResponse,
  type UIState,
} from "./durable-ui.js";
import type { SessionBackendEvent } from "./pi-events.js";

/** Committed documents → the same events as SdkUiBridge, through the shared sanitizer/state owner. */
export class DurableUIProjection {
  private previous: UIState = { requests: {}, notifications: {} };
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
    // A retired document reads as gone, as its last frame (`null`) did before pi-durable 1.5.0.
    this.watch.start(async (call) => {
      if (call.kind === "value" && !this.stopped) this.apply(call.retired ? null : call.value);
    });
  }
  private apply(value: UIState | null): void {
    // Trusted host code owns this document; allowlist fields to guard against
    // accidental event-type overrides without treating it as a security sandbox.
    const current: UIState = { requests: Object.create(null), notifications: Object.create(null) };
    for (const id in value?.requests) {
      if (!Object.hasOwn(value.requests, id)) continue;
      const entry = value.requests[id];
      const request = sanitizeUIRequest(id, entry?.request);
      if (request && entry) current.requests[id] = { taskId: entry.taskId, request };
    }
    for (const slot in value?.notifications) {
      if (!Object.hasOwn(value.notifications, slot)) continue;
      const notification = sanitizeUINotification(slot, value.notifications[slot]);
      if (notification) current.notifications[slot] = notification;
    }
    // A request leaves the document when it is answered, expires, or its call stops.
    for (const id of Object.keys(this.previous.requests))
      if (!current.requests[id]) this.emit({ type: "extension_ui_request_settled", id });
    for (const [id, entry] of Object.entries(current.requests))
      if (!this.previous.requests[id])
        this.emit({ ...entry.request, type: "extension_ui_request" });
    for (const [slot, notification] of Object.entries(current.notifications)) {
      if (!isDeepStrictEqual(this.previous.notifications[slot], notification))
        this.emit({ ...notification, type: "extension_ui_request" });
    }
    this.previous = current;
  }
  /**
   * The app's answer: delivered to the parked call and the request taken down in one commit, so
   * the first answer wins and nothing settles before it is stored. A request whose call ended or
   * was stopped refuses it.
   */
  async respond(response: UIResponse): Promise<boolean> {
    if (this.stopped) return false;
    return this.conversation.commit(async (tx) => {
      const entry = (await tx.doc(DurableUI, this.conversation.id)).requests[response.id];
      if (!entry) return false;
      const [result] = await answerUI(tx, this.conversation.id, [
        { taskId: entry.taskId, response },
      ]);
      return result === "delivered";
    }, BACKGROUND_CONTEXT);
  }
  async stop(): Promise<void> {
    this.stopped = true;
    await this.watch.stop();
  }
}
