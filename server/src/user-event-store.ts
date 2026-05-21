import { EventRing } from "./event-ring.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { ServerMessage } from "./types.js";

export class UserEventStore {
  private seq = 0;
  private ring: EventRing | null = null;

  constructor(
    private readonly metrics?: ServerMetricCollector,
    private readonly ringCapacity = 2000,
  ) {}

  isNotificationLevelMessage(msg: ServerMessage): boolean {
    switch (msg.type) {
      case "permission_request":
      case "permission_expired":
      case "permission_cancelled":
      case "permission_resolved":
      case "permission_auto_reviewed":
      case "extension_ui_request":
      case "agent_start":
      case "agent_end":
      case "state":
      case "session_summary":
      case "session_ended":
      case "session_deleted":
      case "stop_requested":
      case "stop_confirmed":
      case "stop_failed":
      case "error":
        return true;
      default:
        return false;
    }
  }

  private eventRing(): EventRing {
    if (!this.ring) {
      this.ring = new EventRing(this.ringCapacity);
    }
    return this.ring;
  }

  getEventRingStats(): { length: number; capacity: number } | null {
    if (!this.ring) return null;
    return { length: this.ring.length, capacity: this.ring.capacity };
  }

  recordEvent(sessionId: string, msg: ServerMessage): number {
    const seq = ++this.seq;
    const event: ServerMessage = { ...msg, sessionId };
    this.eventRing().push({ seq, event, timestamp: Date.now() });
    this.metrics?.record("server.user_stream_event", 1, { type: msg.type });
    return seq;
  }
}
