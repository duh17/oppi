/**
 * WebSocket command ordering invariants — RQ-WS-002.
 */

import { describe, expect, it, vi } from "vitest";
import { UserStreamMux, type StreamContext } from "../src/stream.js";
import type { ServerMessage, Session, Workspace } from "../src/types.js";

function makeSession(id: string, overrides?: Partial<Session>): Session {
  const now = Date.now();
  return {
    id,
    workspaceId: "w1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeStreamContext(sessions: Session[] = []): StreamContext {
  const sessionMap = new Map(sessions.map((s) => [s.id, s]));
  const subscribers = new Map<string, Set<(msg: ServerMessage) => void>>();

  return {
    storage: {
      getSession: (id: string) => sessionMap.get(id),
      getOwnerName: () => "test-user",
    } as StreamContext["storage"],
    sessions: {
      startSession: vi.fn(async (id: string) => sessionMap.get(id)!),
      subscribe: vi.fn((id: string, cb: (msg: ServerMessage) => void) => {
        if (!subscribers.has(id)) subscribers.set(id, new Set());
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
    ensureSessionContextWindow: (s: Session) => s,
    resolveWorkspaceForSession: () => undefined as Workspace | undefined,
    handleClientMessage: vi.fn(async (_s, msg, send) => {
      send({
        type: "command_result",
        command: msg.type,
        success: true,
        requestId: (msg as { requestId?: string }).requestId,
      });
    }),
    trackConnection: vi.fn(),
    untrackConnection: vi.fn(),
  };
}

function expectStrictlyIncreasing(seqs: number[]): void {
  for (let i = 1; i < seqs.length; i++) {
    expect(seqs[i]).toBeGreaterThan(seqs[i - 1]);
  }
}

describe("RQ-WS-002: stream event recording ordering", () => {
  it("recordUserStreamEvent assigns monotonically increasing streamSeq", () => {
    const mux = new UserStreamMux(makeStreamContext(), { ringCapacity: 100 });

    const seqs = Array.from({ length: 50 }, (_v, i) =>
      mux.recordUserStreamEvent("s1", { type: "text_delta", delta: `chunk-${i}` }),
    );

    expectStrictlyIncreasing(seqs);
  });

  it("interleaved multi-session recording preserves global ordering", () => {
    const mux = new UserStreamMux(makeStreamContext(), { ringCapacity: 100 });

    const seqs = Array.from({ length: 30 }, (_v, i) =>
      mux.recordUserStreamEvent(`s${(i % 3) + 1}`, { type: "text_delta", delta: `msg-${i}` }),
    );

    expectStrictlyIncreasing(seqs);
  });

  it("catch-up replay preserves recording order after interleaved writes", () => {
    const mux = new UserStreamMux(makeStreamContext(), { ringCapacity: 200 });

    for (let i = 0; i < 20; i++) {
      mux.recordUserStreamEvent(`s${(i % 2) + 1}`, { type: "agent_start" });
    }

    const catchUp = mux.getUserStreamCatchUp(0);
    expect(catchUp.catchUpComplete).toBe(true);
    expectStrictlyIncreasing(catchUp.events.map((event) => event.streamSeq!));
  });
});

describe("RQ-WS-002: rapid command sequence invariants", () => {
  it("rapid subscribe/command burst: commands before subscribe are rejected", () => {
    const ctx = makeStreamContext([makeSession("s1")]);
    const mux = new UserStreamMux(ctx);

    mux.recordUserStreamEvent("s1", { type: "agent_start" });
    mux.recordUserStreamEvent("s1", { type: "text_delta", delta: "hello" });

    expect(ctx.handleClientMessage).not.toHaveBeenCalled();
  });

  it("duplicate recordUserStreamEvent calls produce unique seqs", () => {
    const mux = new UserStreamMux(makeStreamContext(), { ringCapacity: 100 });

    const event: ServerMessage = { type: "agent_start" };
    const seqs = [
      mux.recordUserStreamEvent("s1", event),
      mux.recordUserStreamEvent("s1", event),
      mux.recordUserStreamEvent("s1", event),
    ];

    expect(new Set(seqs).size).toBe(3);
    expectStrictlyIncreasing(seqs);
  });

  it("high-frequency burst: 1000 events maintain ordering", () => {
    const mux = new UserStreamMux(makeStreamContext(), { ringCapacity: 2000 });

    const seqs = Array.from({ length: 1000 }, (_v, i) =>
      mux.recordUserStreamEvent(`s${i % 5}`, { type: "text_delta", delta: `d${i}` }),
    );
    expectStrictlyIncreasing(seqs);

    const catchUp = mux.getUserStreamCatchUp(seqs[499]);
    expect(catchUp.catchUpComplete).toBe(true);
    expect(catchUp.events).toHaveLength(500);
    expectStrictlyIncreasing(catchUp.events.map((event) => event.streamSeq!));
  });
});

describe("RQ-WS-002: notification-level filtering invariants", () => {
  it("isNotificationLevelMessage classifies all notification types correctly", () => {
    const mux = new UserStreamMux(makeStreamContext());

    const notificationTypes: ServerMessage["type"][] = [
      "permission_request",
      "permission_expired",
      "permission_cancelled",
      "agent_start",
      "agent_end",
      "state",
      "session_ended",
      "session_deleted",
      "stop_requested",
      "stop_confirmed",
      "stop_failed",
      "error",
    ];

    const fullOnlyTypes: ServerMessage["type"][] = [
      "text_delta",
      "thinking_delta",
      "tool_start",
      "tool_output",
      "tool_end",
      "message_end",
      "compaction_start",
      "compaction_end",
      "retry_start",
      "retry_end",
      "turn_ack",
      "command_result",
      "queue_state",
      "queue_item_started",
      "extension_ui_request",
      "extension_ui_notification",
      "git_status",
    ];

    for (const type of notificationTypes) {
      expect(mux.isNotificationLevelMessage({ type } as ServerMessage)).toBe(true);
    }

    for (const type of fullOnlyTypes) {
      expect(mux.isNotificationLevelMessage({ type } as ServerMessage)).toBe(false);
    }
  });
});

describe("RQ-WS-002: catch-up replay validation", () => {
  it("getUserStreamCatchUp returns ordered session-scoped events", () => {
    const mux = new UserStreamMux(makeStreamContext(), { ringCapacity: 100 });

    mux.recordUserStreamEvent("s1", { type: "agent_start" });
    mux.recordUserStreamEvent("s1", { type: "text_delta", delta: "a" });
    mux.recordUserStreamEvent("s1", { type: "agent_end" });

    const catchUp = mux.getUserStreamCatchUp(0);
    expect(catchUp.catchUpComplete).toBe(true);
    expect(catchUp.events).toHaveLength(3);
    expect(new Set(catchUp.events.map((event) => event.sessionId))).toEqual(new Set(["s1"]));
  });

  it("catch-up at or beyond current seq returns empty", () => {
    const mux = new UserStreamMux(makeStreamContext(), { ringCapacity: 100 });
    const lastSeq = mux.recordUserStreamEvent("s1", { type: "agent_start" });

    const atCurrent = mux.getUserStreamCatchUp(lastSeq);
    const beyondCurrent = mux.getUserStreamCatchUp(9999);

    expect(atCurrent.catchUpComplete).toBe(true);
    expect(atCurrent.events).toHaveLength(0);
    expect(atCurrent.currentSeq).toBe(lastSeq);
    expect(beyondCurrent.events).toHaveLength(0);
  });
});
