import { describe, expect, it, vi } from "vitest";
import { UserStreamMux, type StreamContext } from "../src/stream.js";
import type { ServerMessage } from "../src/types.js";

function makeMux(capacity = 2000): UserStreamMux {
  // Minimal context — replay tests only use recordUserStreamEvent and getUserStreamCatchUp
  const ctx = {
    storage: {},
    sessions: {},
    gate: {},
    ensureSessionContextWindow: (s: unknown) => s,
    resolveWorkspaceForSession: () => undefined,
    handleClientMessage: vi.fn(),
    trackConnection: vi.fn(),
    untrackConnection: vi.fn(),
  } as unknown as StreamContext;

  return new UserStreamMux(ctx, { ringCapacity: capacity });
}

describe("user stream replay reliability", () => {
  it("replays missed events across multiple sessions after disconnect", () => {
    const mux = makeMux();
    const userId = "u-1";

    const seq1 = mux.recordUserStreamEvent(userId, "s-a", { type: "agent_start" });
    const seq2 = mux.recordUserStreamEvent(userId, "s-b", {
      type: "error",
      error: "background failure",
    });
    const seq3 = mux.recordUserStreamEvent(userId, "s-a", {
      type: "session_ended",
      reason: "completed",
    });

    expect([seq1, seq2, seq3]).toEqual([1, 2, 3]);

    const catchUp = mux.getUserStreamCatchUp(userId, 1);
    expect(catchUp.catchUpComplete).toBe(true);
    expect(catchUp.currentSeq).toBe(3);
    expect(
      catchUp.events.map((event) => ({
        streamSeq: event.streamSeq,
        sessionId: event.sessionId,
        type: event.type,
      })),
    ).toEqual([
      { streamSeq: 2, sessionId: "s-b", type: "error" },
      { streamSeq: 3, sessionId: "s-a", type: "session_ended" },
    ]);
  });

  it("signals explicit ring miss for out-of-window since", () => {
    const mux = makeMux(3);
    const userId = "u-1";

    for (let i = 1; i <= 5; i += 1) {
      mux.recordUserStreamEvent(userId, i % 2 === 0 ? "s-b" : "s-a", {
        type: "agent_start",
      });
    }

    const catchUp = mux.getUserStreamCatchUp(userId, 1);
    expect(catchUp.currentSeq).toBe(5);
    expect(catchUp.catchUpComplete).toBe(false);
    expect(catchUp.events).toEqual([]);
  });

  it("returns stable ordered replay with no duplicate seq entries", () => {
    const mux = makeMux();
    const userId = "u-1";

    mux.recordUserStreamEvent(userId, "s-a", { type: "agent_start" });
    mux.recordUserStreamEvent(userId, "s-b", { type: "agent_end" });
    mux.recordUserStreamEvent(userId, "s-a", {
      type: "error",
      error: "err-1",
    });
    mux.recordUserStreamEvent(userId, "s-b", {
      type: "session_ended",
      reason: "done",
    });

    const first = mux.getUserStreamCatchUp(userId, 0);
    const second = mux.getUserStreamCatchUp(userId, 0);

    const firstSeqs = first.events.map((event) => event.streamSeq);
    const secondSeqs = second.events.map((event) => event.streamSeq);

    expect(firstSeqs).toEqual([1, 2, 3, 4]);
    expect(secondSeqs).toEqual([1, 2, 3, 4]);
    expect(new Set(firstSeqs).size).toBe(firstSeqs.length);

    expect(mux.getUserStreamCatchUp(userId, 2).events.map((event) => event.streamSeq)).toEqual([
      3,
      4,
    ]);
  });

  it("holds replay boundary under ring pressure", () => {
    const mux = makeMux(4);
    const userId = "u-1";

    for (let i = 1; i <= 12; i += 1) {
      mux.recordUserStreamEvent(userId, i % 2 === 0 ? "s-b" : "s-a", {
        type: "agent_start",
      });
    }

    const inWindow = mux.getUserStreamCatchUp(userId, 8);
    expect(inWindow.catchUpComplete).toBe(true);
    expect(inWindow.events.map((event) => event.streamSeq)).toEqual([9, 10, 11, 12]);

    const outOfWindow = mux.getUserStreamCatchUp(userId, 7);
    expect(outOfWindow.catchUpComplete).toBe(false);
    expect(outOfWindow.events).toEqual([]);
    expect(outOfWindow.currentSeq).toBe(12);
  });
});
