import { describe, expect, it } from "vitest";
import { EventRing, type SequencedEvent } from "./event-ring.js";
import type { ServerMessage } from "./types.js";

function makeEvent(seq: number, type: ServerMessage["type"] = "agent_start"): SequencedEvent {
  return { seq, event: { type } as ServerMessage, timestamp: Date.now() };
}

describe("EventRing", () => {
  describe("push", () => {
    it("accepts valid positive integer sequence", () => {
      const ring = new EventRing(10);
      expect(() => ring.push(makeEvent(1))).not.toThrow();
      expect(ring.currentSeq).toBe(1);
    });

    it("accepts multiple events in increasing order", () => {
      const ring = new EventRing(10);
      ring.push(makeEvent(1));
      ring.push(makeEvent(2));
      ring.push(makeEvent(5)); // gaps are fine
      expect(ring.currentSeq).toBe(5);
    });

    it("rejects seq 0", () => {
      const ring = new EventRing(10);
      expect(() => ring.push(makeEvent(0))).toThrow("positive integer");
    });

    it("rejects negative seq", () => {
      const ring = new EventRing(10);
      expect(() => ring.push(makeEvent(-1))).toThrow("positive integer");
    });

    it("rejects non-integer seq", () => {
      const ring = new EventRing(10);
      expect(() => ring.push(makeEvent(1.5))).toThrow("positive integer");
    });

    it("rejects NaN seq", () => {
      const ring = new EventRing(10);
      expect(() => ring.push(makeEvent(NaN))).toThrow("positive integer");
    });

    it("rejects duplicate seq (equal to last)", () => {
      const ring = new EventRing(10);
      ring.push(makeEvent(1));
      expect(() => ring.push(makeEvent(1))).toThrow("strictly increasing");
    });

    it("rejects decreasing seq", () => {
      const ring = new EventRing(10);
      ring.push(makeEvent(5));
      expect(() => ring.push(makeEvent(3))).toThrow("strictly increasing");
    });

    it("evicts oldest when at capacity", () => {
      const ring = new EventRing(3);
      ring.push(makeEvent(1));
      ring.push(makeEvent(2));
      ring.push(makeEvent(3));
      expect(ring.oldestSeq).toBe(1);

      ring.push(makeEvent(4));
      expect(ring.oldestSeq).toBe(2);
      expect(ring.currentSeq).toBe(4);
    });

    it("works with capacity 1", () => {
      const ring = new EventRing(1);
      ring.push(makeEvent(1));
      expect(ring.currentSeq).toBe(1);
      expect(ring.oldestSeq).toBe(1);

      ring.push(makeEvent(2));
      expect(ring.currentSeq).toBe(2);
      expect(ring.oldestSeq).toBe(2);
    });
  });

  describe("since", () => {
    it("returns all events when sinceSeq is 0", () => {
      const ring = new EventRing(10);
      ring.push(makeEvent(1));
      ring.push(makeEvent(2));
      ring.push(makeEvent(3));

      const result = ring.since(0);
      expect(result).toHaveLength(3);
      expect(result.map((e) => e.seq)).toEqual([1, 2, 3]);
    });

    it("returns events after sinceSeq", () => {
      const ring = new EventRing(10);
      ring.push(makeEvent(1));
      ring.push(makeEvent(2));
      ring.push(makeEvent(3));

      const result = ring.since(1);
      expect(result).toHaveLength(2);
      expect(result.map((e) => e.seq)).toEqual([2, 3]);
    });

    it("returns empty when sinceSeq equals currentSeq", () => {
      const ring = new EventRing(10);
      ring.push(makeEvent(1));
      ring.push(makeEvent(2));

      expect(ring.since(2)).toEqual([]);
    });

    it("returns empty when sinceSeq is beyond currentSeq", () => {
      const ring = new EventRing(10);
      ring.push(makeEvent(1));

      expect(ring.since(999)).toEqual([]);
    });

    it("returns empty on empty ring", () => {
      const ring = new EventRing(10);
      expect(ring.since(0)).toEqual([]);
    });

    it("returns events after eviction", () => {
      const ring = new EventRing(3);
      ring.push(makeEvent(1));
      ring.push(makeEvent(2));
      ring.push(makeEvent(3));
      ring.push(makeEvent(4)); // evicts 1

      const result = ring.since(2);
      expect(result.map((e) => e.seq)).toEqual([3, 4]);
    });

    it("handles since with seq that was evicted — returns from ring start", () => {
      const ring = new EventRing(3);
      ring.push(makeEvent(1));
      ring.push(makeEvent(2));
      ring.push(makeEvent(3));
      ring.push(makeEvent(4)); // evicts 1
      ring.push(makeEvent(5)); // evicts 2

      // Asking for events since seq 1 (evicted) — all remaining events are > 1
      const result = ring.since(1);
      expect(result.map((e) => e.seq)).toEqual([3, 4, 5]);
    });

    it("handles non-contiguous seqs correctly", () => {
      const ring = new EventRing(10);
      ring.push(makeEvent(10));
      ring.push(makeEvent(20));
      ring.push(makeEvent(30));

      expect(ring.since(15).map((e) => e.seq)).toEqual([20, 30]);
      expect(ring.since(10).map((e) => e.seq)).toEqual([20, 30]);
      expect(ring.since(9).map((e) => e.seq)).toEqual([10, 20, 30]);
    });
  });

  describe("canServe", () => {
    it("returns true on empty ring for any sinceSeq", () => {
      const ring = new EventRing(10);
      expect(ring.canServe(0)).toBe(true);
      expect(ring.canServe(100)).toBe(true);
    });

    it("returns true when sinceSeq equals oldestSeq - 1", () => {
      const ring = new EventRing(10);
      ring.push(makeEvent(5));
      // oldestSeq is 5, so sinceSeq=4 means "give me everything from 5 onwards"
      expect(ring.canServe(4)).toBe(true);
    });

    it("returns true when sinceSeq equals oldestSeq", () => {
      const ring = new EventRing(10);
      ring.push(makeEvent(5));
      ring.push(makeEvent(6));
      // sinceSeq=5 means "give me events after 5" (i.e., seq 6) — ring has it
      expect(ring.canServe(5)).toBe(true);
    });

    it("returns false when sinceSeq is older than oldestSeq - 1", () => {
      const ring = new EventRing(3);
      ring.push(makeEvent(5));
      ring.push(makeEvent(6));
      ring.push(makeEvent(7));
      // oldestSeq=5, sinceSeq=3 means client wants seq 4+, but we only have 5+
      expect(ring.canServe(3)).toBe(false);
    });

    // BUG PROBE: canServe boundary after eviction
    // The condition `sinceSeq >= this.oldestSeq - 1` means asking for
    // sinceSeq = oldestSeq - 1 returns true, but since(oldestSeq - 1) will
    // return all events in the ring. This is correct behavior — the client
    // is saying "I have up to seq N, give me N+1 onwards" and we have N+1.
    it("returns true at exact boundary after evictions", () => {
      const ring = new EventRing(3);
      ring.push(makeEvent(1));
      ring.push(makeEvent(2));
      ring.push(makeEvent(3));
      ring.push(makeEvent(4)); // evicts 1
      ring.push(makeEvent(5)); // evicts 2

      // oldestSeq = 3, so canServe(2) = true (2 >= 3-1)
      expect(ring.canServe(2)).toBe(true);
      // And since(2) returns [3,4,5] — correct, client gets everything they missed
      expect(ring.since(2).map((e) => e.seq)).toEqual([3, 4, 5]);

      // But canServe(1) = false (1 < 3-1=2) — client missed seq 2 which is gone
      expect(ring.canServe(1)).toBe(false);
    });
  });

  describe("currentSeq / oldestSeq", () => {
    it("returns 0 for both on empty ring", () => {
      const ring = new EventRing(10);
      expect(ring.currentSeq).toBe(0);
      expect(ring.oldestSeq).toBe(0);
    });

    it("tracks oldest correctly through evictions", () => {
      const ring = new EventRing(2);
      ring.push(makeEvent(10));
      expect(ring.oldestSeq).toBe(10);
      ring.push(makeEvent(20));
      expect(ring.oldestSeq).toBe(10);
      ring.push(makeEvent(30)); // evicts 10
      expect(ring.oldestSeq).toBe(20);
    });
  });
});
