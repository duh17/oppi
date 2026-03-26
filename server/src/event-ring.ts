/**
 * Bounded ring buffer of sequenced durable events.
 *
 * Used by SessionManager (per-session) and UserStreamMux (per-user)
 * to support reconnect catch-up without unbounded memory growth.
 *
 * Implementation uses a circular buffer with head/tail pointers
 * to avoid O(n) Array.shift() on every push at capacity.
 * `since()` uses binary search on monotonically increasing seqs.
 */

import type { ServerMessage } from "./types.js";

export interface SequencedEvent {
  seq: number;
  event: ServerMessage;
  timestamp: number;
}

export class EventRing {
  private buf: (SequencedEvent | undefined)[];
  private head = 0; // index of oldest element
  private len = 0; // number of stored elements
  private readonly cap: number;
  /** Cached seq of the most recently pushed event. Avoids a modular index
   *  lookup on every push for the monotonicity check, and makes currentSeq O(1). */
  private _lastSeq = 0;

  constructor(capacity = 500) {
    this.cap = capacity;
    this.buf = new Array(capacity);
  }

  push(event: SequencedEvent): void {
    const seq = event.seq;
    // Faster integer check than Number.isInteger (avoids function call overhead).
    if (seq <= 0 || (seq | 0) !== seq) {
      throw new Error(`EventRing sequence must be a positive integer (received ${seq})`);
    }

    if (this.len > 0 && seq <= this._lastSeq) {
      throw new Error(
        `EventRing sequence must be strictly increasing (last=${this._lastSeq}, next=${seq})`,
      );
    }
    this._lastSeq = seq;

    if (this.len < this.cap) {
      // Not yet full — append at tail
      this.buf[(this.head + this.len) % this.cap] = event;
      this.len++;
    } else {
      // Full — overwrite oldest (head) and advance head
      this.buf[this.head] = event;
      this.head = (this.head + 1) % this.cap;
    }
  }

  since(sinceSeq: number): SequencedEvent[] {
    if (this.len === 0) return [];

    // Binary search for first event with seq > sinceSeq
    let lo = 0;
    let hi = this.len;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      // eslint-disable-next-line @typescript-eslint/no-non-null-assertion -- ring buffer slot guaranteed occupied within [0, len)
      if (this.buf[(this.head + mid) % this.cap]!.seq > sinceSeq) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }

    if (lo >= this.len) return [];

    // Copy matching events into result array
    const count = this.len - lo;
    const result: SequencedEvent[] = new Array(count);
    for (let i = 0; i < count; i++) {
      // eslint-disable-next-line @typescript-eslint/no-non-null-assertion -- ring buffer slot guaranteed occupied
      result[i] = this.buf[(this.head + lo + i) % this.cap]!;
    }
    return result;
  }

  get currentSeq(): number {
    return this.len === 0 ? 0 : this._lastSeq;
  }

  get oldestSeq(): number {
    if (this.len === 0) return 0;
    // eslint-disable-next-line @typescript-eslint/no-non-null-assertion -- head always occupied when len > 0
    return this.buf[this.head]!.seq;
  }

  canServe(sinceSeq: number): boolean {
    // eslint-disable-next-line @typescript-eslint/no-non-null-assertion -- head always occupied when len > 0
    return this.len === 0 || sinceSeq >= this.buf[this.head]!.seq - 1;
  }

  /** Number of events currently stored. */
  get length(): number {
    return this.len;
  }

  /** Maximum capacity of the ring buffer. */
  get capacity(): number {
    return this.cap;
  }
}
