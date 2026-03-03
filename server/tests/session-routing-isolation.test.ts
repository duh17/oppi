/**
 * Session routing isolation tests — RQ-ROUTE-002.
 */

import { describe, expect, it, vi } from "vitest";
import { UserStreamMux, type StreamContext } from "../src/stream.js";
import type { ServerMessage, Session, Workspace } from "../src/types.js";

function makeSession(id: string, workspaceId = "w1"): Session {
  const now = Date.now();
  return {
    id,
    workspaceId,
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
  };
}

type SubscribeCallback = (msg: ServerMessage) => void;

function makeRoutingContext(sessions: Session[]): {
  ctx: StreamContext;
  subscribers: Map<string, Set<SubscribeCallback>>;
  broadcast: (sessionId: string, msg: ServerMessage) => void;
} {
  const sessionMap = new Map(sessions.map((session) => [session.id, session]));
  const subscribers = new Map<string, Set<SubscribeCallback>>();

  const ctx: StreamContext = {
    storage: {
      getSession: (id: string) => sessionMap.get(id),
      getOwnerName: () => "test-user",
    } as StreamContext["storage"],
    sessions: {
      startSession: vi.fn(async (id: string) => sessionMap.get(id)!),
      subscribe: vi.fn((id: string, cb: SubscribeCallback) => {
        if (!subscribers.has(id)) {
          subscribers.set(id, new Set());
        }
        subscribers.get(id)?.add(cb);
        return () => subscribers.get(id)?.delete(cb);
      }),
      getCurrentSeq: vi.fn(() => 0),
      getActiveSession: vi.fn((id: string) => sessionMap.get(id)),
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

  return {
    ctx,
    subscribers,
    broadcast: (sessionId: string, msg: ServerMessage) => {
      for (const callback of subscribers.get(sessionId) ?? []) {
        callback(msg);
      }
    },
  };
}

describe("RQ-ROUTE-002: event recording isolation", () => {
  it("events carry the recording sessionId in global order", () => {
    const { ctx } = makeRoutingContext([
      makeSession("s1", "w1"),
      makeSession("s2", "w2"),
      makeSession("s3", "w1"),
    ]);
    const mux = new UserStreamMux(ctx, { ringCapacity: 200 });

    const sequence = [
      ["s1", { type: "agent_start" }],
      ["s2", { type: "agent_start" }],
      ["s3", { type: "agent_start" }],
      ["s1", { type: "text_delta", delta: "a" }],
      ["s2", { type: "text_delta", delta: "b" }],
      ["s3", { type: "text_delta", delta: "c" }],
    ] as const;

    for (const [sessionId, event] of sequence) {
      mux.recordUserStreamEvent(sessionId, event);
    }

    expect(mux.getUserStreamCatchUp(0).events.map((event) => event.sessionId)).toEqual([
      "s1",
      "s2",
      "s3",
      "s1",
      "s2",
      "s3",
    ]);
  });

  it("recording overwrites conflicting sessionId on payload", () => {
    const { ctx } = makeRoutingContext([makeSession("target"), makeSession("other")]);
    const mux = new UserStreamMux(ctx, { ringCapacity: 100 });

    mux.recordUserStreamEvent("target", {
      type: "text_delta",
      delta: "data",
      sessionId: "other",
    });

    const [event] = mux.getUserStreamCatchUp(0).events;
    expect(event.sessionId).toBe("target");
  });

  it("recording orphan events for deleted sessions still works", () => {
    const { ctx } = makeRoutingContext([]);
    const mux = new UserStreamMux(ctx, { ringCapacity: 100 });

    const seq = mux.recordUserStreamEvent("ghost-session", {
      type: "session_ended",
      reason: "deleted",
    });

    expect(seq).toBeGreaterThan(0);
    expect(mux.getUserStreamCatchUp(0).events[0].sessionId).toBe("ghost-session");
  });
});

describe("RQ-ROUTE-002: subscriber callback isolation", () => {
  it("callback only fires for its subscribed session", () => {
    const { ctx, broadcast } = makeRoutingContext([makeSession("sa"), makeSession("sb")]);

    const cbA = vi.fn();
    const cbB = vi.fn();
    ctx.sessions.subscribe("sa", cbA);
    ctx.sessions.subscribe("sb", cbB);

    const eventA: ServerMessage = { type: "text_delta", delta: "for A" };
    const eventB: ServerMessage = { type: "text_delta", delta: "for B" };
    broadcast("sa", eventA);
    broadcast("sb", eventB);

    expect(cbA).toHaveBeenCalledTimes(1);
    expect(cbA).toHaveBeenCalledWith(eventA);
    expect(cbB).toHaveBeenCalledTimes(1);
    expect(cbB).toHaveBeenCalledWith(eventB);
  });

  it("unsubscribe detaches only that session callback", () => {
    const { ctx, subscribers, broadcast } = makeRoutingContext([
      makeSession("sa"),
      makeSession("sb"),
    ]);

    const cbA = vi.fn();
    const cbB = vi.fn();
    const unsubscribeA = ctx.sessions.subscribe("sa", cbA);
    ctx.sessions.subscribe("sb", cbB);

    expect(subscribers.get("sa")?.size).toBe(1);
    expect(subscribers.get("sb")?.size).toBe(1);

    unsubscribeA();
    broadcast("sa", { type: "text_delta", delta: "for A" });
    broadcast("sb", { type: "text_delta", delta: "for B" });

    expect(cbA).not.toHaveBeenCalled();
    expect(cbB).toHaveBeenCalledTimes(1);
    expect(subscribers.get("sa")?.size).toBe(0);
    expect(subscribers.get("sb")?.size).toBe(1);
  });
});

describe("RQ-ROUTE-002: ring + outbound consistency", () => {
  it("wrapped ring signals incomplete catch-up", () => {
    const { ctx } = makeRoutingContext([]);
    const mux = new UserStreamMux(ctx, { ringCapacity: 5 });

    for (let index = 0; index < 10; index++) {
      mux.recordUserStreamEvent("s1", { type: "text_delta", delta: `d${index}` });
    }

    expect(mux.getUserStreamCatchUp(1).catchUpComplete).toBe(false);
  });

  it("recordUserStreamEvent stamps sessionId + streamSeq across event types", () => {
    const { ctx } = makeRoutingContext([makeSession("test-session")]);
    const mux = new UserStreamMux(ctx, { ringCapacity: 100 });

    const events: ServerMessage[] = [
      { type: "agent_start" },
      { type: "text_delta", delta: "hi" },
      { type: "tool_start", tool: "bash", args: {} },
      { type: "tool_output", output: "ok" },
      { type: "tool_end", tool: "bash" },
      { type: "agent_end" },
      { type: "state", session: makeSession("test-session") },
      { type: "error", error: "oops" },
    ];

    for (const event of events) {
      mux.recordUserStreamEvent("test-session", event);
    }

    for (const event of mux.getUserStreamCatchUp(0).events) {
      expect(event.sessionId).toBe("test-session");
      expect(event.streamSeq).toBeTypeOf("number");
    }
  });
});
