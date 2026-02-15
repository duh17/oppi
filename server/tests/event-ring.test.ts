import { describe, expect, it } from "vitest";
import { EventRing } from "../src/event-ring.js";

describe("EventRing", () => {
  it("returns events strictly newer than since seq", () => {
    const ring = new EventRing(10);

    ring.push({ seq: 1, event: { type: "agent_start", seq: 1 }, timestamp: 1 });
    ring.push({ seq: 2, event: { type: "tool_start", tool: "bash", args: {}, seq: 2 }, timestamp: 2 });
    ring.push({ seq: 3, event: { type: "tool_end", tool: "bash", seq: 3 }, timestamp: 3 });

    const events = ring.since(1);
    expect(events.map((e) => e.seq)).toEqual([2, 3]);
  });

  it("enforces ring capacity", () => {
    const ring = new EventRing(3);

    for (let seq = 1; seq <= 5; seq += 1) {
      ring.push({
        seq,
        event: { type: "agent_start", seq },
        timestamp: seq,
      });
    }

    expect(ring.oldestSeq).toBe(3);
    expect(ring.currentSeq).toBe(5);
    expect(ring.since(0).map((e) => e.seq)).toEqual([3, 4, 5]);
  });

  it("reports whether catch-up can be served without gaps", () => {
    const ring = new EventRing(3);

    ring.push({ seq: 5, event: { type: "agent_start", seq: 5 }, timestamp: 1 });
    ring.push({ seq: 6, event: { type: "agent_end", seq: 6 }, timestamp: 2 });
    ring.push({ seq: 7, event: { type: "tool_start", tool: "read", args: {}, seq: 7 }, timestamp: 3 });

    expect(ring.canServe(4)).toBe(true);
    expect(ring.canServe(5)).toBe(true);
    expect(ring.canServe(3)).toBe(false);
  });

  it("enforces strictly increasing sequences", () => {
    const ring = new EventRing(5);

    ring.push({ seq: 1, event: { type: "agent_start", seq: 1 }, timestamp: 1 });

    expect(() =>
      ring.push({ seq: 1, event: { type: "agent_end", seq: 1 }, timestamp: 2 }),
    ).toThrow("strictly increasing");

    expect(() =>
      ring.push({ seq: 0, event: { type: "agent_end", seq: 0 }, timestamp: 3 }),
    ).toThrow("positive integer");
  });
});
