/**
 * Bounded ring buffer of sequenced durable events.
 *
 * Used by SessionManager (per-session) and UserStreamMux (per-user)
 * to support reconnect catch-up without unbounded memory growth.
 */

import type { ServerMessage } from "./types.js";

export interface SequencedEvent {
  seq: number;
  event: ServerMessage;
  timestamp: number;
}

export class EventRing {
  private events: SequencedEvent[] = [];

  constructor(private readonly capacity = 500) {}

  push(event: SequencedEvent): void {
    if (!Number.isInteger(event.seq) || event.seq <= 0) {
      throw new Error(`EventRing sequence must be a positive integer (received ${event.seq})`);
    }

    const last = this.events[this.events.length - 1];
    if (last && event.seq <= last.seq) {
      throw new Error(
        `EventRing sequence must be strictly increasing (last=${last.seq}, next=${event.seq})`,
      );
    }

    this.events.push(event);
    if (this.events.length > this.capacity) {
      this.events.shift();
    }
  }

  since(sinceSeq: number): SequencedEvent[] {
    const idx = this.events.findIndex((entry) => entry.seq > sinceSeq);
    return idx === -1 ? [] : this.events.slice(idx);
  }

  get currentSeq(): number {
    const last = this.events[this.events.length - 1];
    return last?.seq ?? 0;
  }

  get oldestSeq(): number {
    return this.events[0]?.seq ?? 0;
  }

  canServe(sinceSeq: number): boolean {
    return this.events.length === 0 || sinceSeq >= this.oldestSeq - 1;
  }
}
