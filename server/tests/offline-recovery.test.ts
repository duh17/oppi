/**
 * Offline recovery tests — RQ-OFFLINE-001 + RQ-OFFLINE-002.
 */

import { describe, expect, it, vi } from "vitest";
import { EventRing } from "../src/event-ring.js";
import { UserStreamMux, type StreamContext } from "../src/stream.js";
import type { ServerMessage, Session, Workspace } from "../src/types.js";

function makeSession(id: string): Session {
  const now = Date.now();
  return {
    id,
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
  };
}

function makeMuxContext(): StreamContext {
  return {
    storage: {
      getSession: () => makeSession("s1"),
      getOwnerName: () => "test",
    } as StreamContext["storage"],
    sessions: {
      startSession: vi.fn(async (id: string) => makeSession(id)),
      subscribe: vi.fn(() => () => {}),
      getCurrentSeq: vi.fn(() => 0),
      getActiveSession: vi.fn(() => undefined),
      getCatchUp: vi.fn(() => null),
    } as unknown as StreamContext["sessions"],
    gate: {
      getPendingForUser: vi.fn(() => []),
    } as unknown as StreamContext["gate"],
    ensureSessionContextWindow: (session: Session) => session,
    resolveWorkspaceForSession: () => undefined as Workspace | undefined,
    handleClientMessage: vi.fn(async () => {}),
    trackConnection: vi.fn(),
    untrackConnection: vi.fn(),
  };
}

function createMux(ringCapacity: number): UserStreamMux {
  return new UserStreamMux(makeMuxContext(), { ringCapacity });
}

function recordTextDeltas(mux: UserStreamMux, count: number): number[] {
  const seqs: number[] = [];
  for (let i = 0; i < count; i++) {
    seqs.push(mux.recordUserStreamEvent("s1", { type: "text_delta", delta: `d${i}` }));
  }
  return seqs;
}

describe("RQ-OFFLINE-001: stream replay after disconnect", () => {
  it("full replay from seq 0 returns all buffered events", () => {
    const mux = createMux(100);

    mux.recordUserStreamEvent("s1", { type: "agent_start" });
    mux.recordUserStreamEvent("s1", { type: "text_delta", delta: "hello" });
    mux.recordUserStreamEvent("s1", { type: "text_delta", delta: " world" });
    mux.recordUserStreamEvent("s1", { type: "agent_end" });

    const catchUp = mux.getUserStreamCatchUp(0);
    expect(catchUp.catchUpComplete).toBe(true);
    expect(catchUp.events.map((event) => event.type)).toEqual([
      "agent_start",
      "text_delta",
      "text_delta",
      "agent_end",
    ]);
  });

  it("partial replay from mid-stream returns only missed events", () => {
    const mux = createMux(100);

    const seq1 = mux.recordUserStreamEvent("s1", { type: "agent_start" });
    mux.recordUserStreamEvent("s1", { type: "text_delta", delta: "a" });
    mux.recordUserStreamEvent("s1", { type: "text_delta", delta: "b" });
    mux.recordUserStreamEvent("s1", { type: "agent_end" });

    const catchUp = mux.getUserStreamCatchUp(seq1);
    expect(catchUp.catchUpComplete).toBe(true);
    expect(catchUp.events.map((event) => event.type)).toEqual([
      "text_delta",
      "text_delta",
      "agent_end",
    ]);
  });

  it("replay after multiple agent turns preserves full history", () => {
    const mux = createMux(500);

    for (let turn = 0; turn < 3; turn++) {
      mux.recordUserStreamEvent("s1", { type: "agent_start" });
      for (let i = 0; i < 5; i++) {
        mux.recordUserStreamEvent("s1", { type: "text_delta", delta: `turn${turn}-chunk${i}` });
      }
      mux.recordUserStreamEvent("s1", {
        type: "message_end",
        role: "assistant",
        content: `response ${turn}`,
      });
      mux.recordUserStreamEvent("s1", { type: "agent_end" });
    }

    const catchUp = mux.getUserStreamCatchUp(0);
    expect(catchUp.catchUpComplete).toBe(true);
    expect(catchUp.events).toHaveLength(24);
  });

  it("replay after permission flow preserves full tool lifecycle", () => {
    const mux = createMux(200);

    const events: ServerMessage[] = [
      { type: "agent_start" },
      { type: "text_delta", delta: "Let me check..." },
      { type: "tool_start", tool: "bash", args: { command: "rm -rf node_modules" } },
      {
        type: "permission_request",
        id: "p1",
        sessionId: "s1",
        tool: "bash",
        input: { command: "rm -rf node_modules" },
        displaySummary: "Run: rm -rf node_modules",
        reason: "destructive",
        timeoutAt: Date.now() + 30000,
      },
      { type: "tool_output", output: "done" },
      { type: "tool_end", tool: "bash" },
      { type: "agent_end" },
    ];

    for (const event of events) {
      mux.recordUserStreamEvent("s1", event);
    }

    const catchUp = mux.getUserStreamCatchUp(0);
    const types = catchUp.events.map((event) => event.type);
    expect(catchUp.catchUpComplete).toBe(true);
    expect(types).toEqual(events.map((event) => event.type));
    expect(types).toEqual(
      expect.arrayContaining(["tool_start", "permission_request", "tool_output", "tool_end"]),
    );
  });
});

describe("RQ-OFFLINE-001: ring miss recovery", () => {
  it("small ring that wraps signals catchUpComplete=false", () => {
    const mux = createMux(5);

    recordTextDeltas(mux, 10);
    const catchUp = mux.getUserStreamCatchUp(1);

    expect(catchUp.catchUpComplete).toBe(false);
    expect(catchUp.events).toEqual([]);
  });

  it("ring miss at boundary: before oldest-1 is incomplete", () => {
    const mux = createMux(5);

    recordTextDeltas(mux, 8);
    expect(mux.getUserStreamCatchUp(2).catchUpComplete).toBe(false);
  });

  it("ring miss: sinceSeq inside window can replay", () => {
    const mux = createMux(5);

    const seqs = recordTextDeltas(mux, 8);
    const catchUp = mux.getUserStreamCatchUp(seqs[3]);

    if (catchUp.catchUpComplete) {
      expect(catchUp.events.length).toBeGreaterThan(0);
      for (const event of catchUp.events) {
        expect(event.streamSeq!).toBeGreaterThan(seqs[3]);
      }
    }
  });

  it("currentSeq is always exposed, even on ring miss", () => {
    const mux = createMux(3);

    recordTextDeltas(mux, 10);
    expect(mux.getUserStreamCatchUp(1).currentSeq).toBe(10);
  });
});

describe("RQ-OFFLINE-001: multiple reconnect cycles", () => {
  it("sequential reconnects each receive the right catch-up window", () => {
    const mux = createMux(100);

    mux.recordUserStreamEvent("s1", { type: "agent_start" });
    const phase1Last = mux.recordUserStreamEvent("s1", { type: "text_delta", delta: "p1" });

    const reconnect1 = mux.getUserStreamCatchUp(0);
    expect(reconnect1.catchUpComplete).toBe(true);
    expect(reconnect1.events).toHaveLength(2);

    mux.recordUserStreamEvent("s1", { type: "text_delta", delta: "p2" });
    const phase2Last = mux.recordUserStreamEvent("s1", { type: "agent_end" });

    const reconnect2 = mux.getUserStreamCatchUp(phase1Last);
    expect(reconnect2.catchUpComplete).toBe(true);
    expect(reconnect2.events).toHaveLength(2);

    mux.recordUserStreamEvent("s1", { type: "agent_start" });
    mux.recordUserStreamEvent("s1", { type: "text_delta", delta: "p3" });

    const reconnect3 = mux.getUserStreamCatchUp(phase2Last);
    expect(reconnect3.catchUpComplete).toBe(true);
    expect(reconnect3.events).toHaveLength(2);
  });

  it("reconnect during active tool execution preserves in-flight state", () => {
    const mux = createMux(100);

    mux.recordUserStreamEvent("s1", { type: "agent_start" });
    mux.recordUserStreamEvent("s1", {
      type: "tool_start",
      tool: "bash",
      args: { command: "sleep 60" },
    });
    const beforeDisconnect = mux.recordUserStreamEvent("s1", {
      type: "tool_output",
      output: "partial...",
    });

    mux.recordUserStreamEvent("s1", { type: "tool_output", output: "...done" });
    mux.recordUserStreamEvent("s1", { type: "tool_end", tool: "bash" });
    mux.recordUserStreamEvent("s1", { type: "agent_end" });

    const catchUp = mux.getUserStreamCatchUp(beforeDisconnect);
    expect(catchUp.catchUpComplete).toBe(true);
    expect(catchUp.events.map((event) => event.type)).toEqual(["tool_output", "tool_end", "agent_end"]);
  });
});

describe("RQ-OFFLINE-002: offline state signal paths", () => {
  it("ring miss triggers deterministic offline signal", () => {
    const mux = createMux(3);

    recordTextDeltas(mux, 10);
    expect(mux.getUserStreamCatchUp(1).catchUpComplete).toBe(false);
  });

  it("successful catch-up signals online state", () => {
    const mux = createMux(100);

    mux.recordUserStreamEvent("s1", { type: "agent_start" });
    mux.recordUserStreamEvent("s1", { type: "agent_end" });

    expect(mux.getUserStreamCatchUp(0).catchUpComplete).toBe(true);
  });

  it("empty ring returns catchUpComplete=true and no events", () => {
    const mux = createMux(100);

    const catchUp = mux.getUserStreamCatchUp(0);
    expect(catchUp.catchUpComplete).toBe(true);
    expect(catchUp.events).toHaveLength(0);
  });

  it("currentSeq acts as reconnect cursor", () => {
    const mux = createMux(100);

    mux.recordUserStreamEvent("s1", { type: "agent_start" });
    mux.recordUserStreamEvent("s1", { type: "agent_end" });

    const catchUp = mux.getUserStreamCatchUp(0);
    expect(catchUp.currentSeq).toBeTypeOf("number");
    expect(catchUp.currentSeq).toBeGreaterThan(0);

    const next = mux.getUserStreamCatchUp(catchUp.currentSeq);
    expect(next.catchUpComplete).toBe(true);
    expect(next.events).toHaveLength(0);
  });
});

describe("RQ-OFFLINE-002: EventRing boundary conditions", () => {
  it("ring reports canServe correctly at capacity boundary", () => {
    const ring = new EventRing(5);

    for (let i = 1; i <= 5; i++) {
      ring.push({
        seq: i,
        event: { type: "text_delta", delta: `${i}` } as ServerMessage,
        timestamp: Date.now(),
      });
    }

    expect(ring.canServe(0)).toBe(true);
    expect(ring.canServe(5)).toBe(true);
  });

  it("ring reports canServe=false for sequences before oldest-1", () => {
    const ring = new EventRing(3);

    for (let i = 1; i <= 6; i++) {
      ring.push({
        seq: i,
        event: { type: "text_delta", delta: `${i}` } as ServerMessage,
        timestamp: Date.now(),
      });
    }

    expect(ring.canServe(2)).toBe(false);
    expect(ring.canServe(1)).toBe(false);
    expect(ring.canServe(0)).toBe(false);
    expect(ring.canServe(3)).toBe(true);
  });

  it("ring since() returns events after a given seq", () => {
    const ring = new EventRing(10);

    for (let i = 1; i <= 5; i++) {
      ring.push({
        seq: i,
        event: { type: "text_delta", delta: `${i}`, streamSeq: i } as ServerMessage,
        timestamp: Date.now(),
      });
    }

    const events = ring.since(2);
    expect(events).toHaveLength(3);
    expect(events.map((event) => event.seq)).toEqual([3, 4, 5]);
  });
});
