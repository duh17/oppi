/**
 * Bounded ring buffer of sequenced messages (the numbered copies the broadcaster
 * delivers to subscribers).
 *
 * Used by SessionBroadcaster to support per-session reconnect catch-up without
 * unbounded memory growth.
 *
 * Implementation uses a circular buffer with head/tail pointers
 * to avoid O(n) Array.shift() on every push at capacity.
 * `since()` uses binary search on monotonically increasing seqs.
 */

import type { ServerMessage } from "./types.js";

/** A server message carrying its per-session sequence number. */
export type SequencedMessage = ServerMessage & { seq: number };

export class EventRing {
  private buf: (SequencedMessage | undefined)[];
  private head = 0; // index of oldest element
  private len = 0; // number of stored elements
  private readonly cap: number;
  /** Cached seq of the most recently pushed message. Avoids a modular index
   *  lookup on every push for the monotonicity check. */
  private _lastSeq = 0;

  constructor(capacity = 500) {
    this.cap = capacity;
    this.buf = new Array(capacity);
  }

  push(message: SequencedMessage): void {
    const seq = message.seq;
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
      this.buf[(this.head + this.len) % this.cap] = message;
      this.len++;
    } else {
      // Full — overwrite oldest (head) and advance head
      this.buf[this.head] = message;
      this.head = (this.head + 1) % this.cap;
    }
  }

  since(sinceSeq: number): SequencedMessage[] {
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
    const result: SequencedMessage[] = new Array(count);
    for (let i = 0; i < count; i++) {
      // eslint-disable-next-line @typescript-eslint/no-non-null-assertion -- ring buffer slot guaranteed occupied
      result[i] = this.buf[(this.head + lo + i) % this.cap]!;
    }
    return result;
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
