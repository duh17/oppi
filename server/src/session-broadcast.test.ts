import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  SessionBroadcaster,
  type BroadcastSessionState,
  type SessionBroadcastEvent,
  type SessionBroadcasterDeps,
} from "./session-broadcast.js";
import { EventRing } from "./event-ring.js";
import type { ServerMessage, Session } from "./types.js";

function makeSession(id = "sess-1"): Session {
  return {
    id,
    status: "ready",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
  };
}

function makeActive(session?: Session): BroadcastSessionState {
  const sess = session ?? makeSession();
  return {
    session: sess,
    subscribers: new Set(),
    seq: 0,
    eventRing: new EventRing(100),
  };
}

interface TestHarness {
  deps: SessionBroadcasterDeps;
  broadcaster: SessionBroadcaster;
  activeSessions: Map<string, BroadcastSessionState>;
  emitted: SessionBroadcastEvent[];
  saved: Session[];
}

function createHarness(saveDebounceMs = 50): TestHarness {
  const activeSessions = new Map<string, BroadcastSessionState>();
  const emitted: SessionBroadcastEvent[] = [];
  const saved: Session[] = [];

  const deps: SessionBroadcasterDeps = {
    getActiveSession: (key) => activeSessions.get(key),
    emitSessionEvent: (payload) => emitted.push(payload),
    saveSession: (session) => saved.push(structuredClone(session)),
  };

  const broadcaster = new SessionBroadcaster(deps, saveDebounceMs);
  return { deps, broadcaster, activeSessions, emitted, saved };
}

describe("SessionBroadcaster", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe("durable vs ephemeral routing", () => {
    it("routes durable message types through sequencing path", () => {
      const { broadcaster, activeSessions, emitted } = createHarness();
      const active = makeActive();
      activeSessions.set("k1", active);

      broadcaster.broadcast("k1", { type: "agent_start" } as ServerMessage);

      expect(active.seq).toBe(1);
      expect(emitted).toHaveLength(1);
      expect(emitted[0]!.durable).toBe(true);
      expect(emitted[0]!.event.seq).toBe(1);
    });

    it("routes ephemeral message types without sequencing", () => {
      const { broadcaster, activeSessions } = createHarness();
      const active = makeActive();
      activeSessions.set("k1", active);

      const received: ServerMessage[] = [];
      active.subscribers.add((msg) => received.push(msg));

      broadcaster.broadcast("k1", { type: "text_delta", delta: "hi" } as ServerMessage);

      expect(active.seq).toBe(0); // no seq increment
      expect(received).toHaveLength(1);
      expect(received[0]!.seq).toBeUndefined(); // no seq assigned
    });

    it("only emits 'state' ephemeral events to global observers", () => {
      const { broadcaster, activeSessions, emitted } = createHarness();
      const active = makeActive();
      activeSessions.set("k1", active);

      // text_delta is ephemeral but NOT emitted globally
      broadcaster.broadcast("k1", { type: "text_delta", delta: "hi" } as ServerMessage);
      expect(emitted).toHaveLength(0);

      // state IS emitted globally
      broadcaster.broadcast("k1", {
        type: "state",
        session: active.session,
      } as ServerMessage);
      expect(emitted).toHaveLength(1);
      expect(emitted[0]!.durable).toBe(false);
    });

    // Verify every durable type is actually in the set
    const expectedDurableTypes: ServerMessage["type"][] = [
      "agent_start",
      "agent_end",
      "message_end",
      "tool_start",
      "tool_end",
      "permission_request",
      "permission_expired",
      "permission_cancelled",
      "stop_requested",
      "stop_confirmed",
      "stop_failed",
      "session_ended",
      "session_deleted",
      "error",
    ];

    for (const durableType of expectedDurableTypes) {
      it(`treats "${durableType}" as durable`, () => {
        const { broadcaster, activeSessions } = createHarness();
        const active = makeActive();
        activeSessions.set("k1", active);

        // Build a minimal message of the right type — the broadcast logic only checks .type
        broadcaster.broadcast("k1", { type: durableType } as ServerMessage);
        expect(active.seq).toBe(1);
      });
    }

    // Verify ephemeral types don't get sequenced
    const expectedEphemeralTypes: ServerMessage["type"][] = [
      "text_delta",
      "thinking_delta",
      "tool_output",
      "state",
      "connected",
      "command_result",
      "compaction_start",
      "compaction_end",
      "retry_start",
      "retry_end",
    ];

    for (const ephType of expectedEphemeralTypes) {
      it(`treats "${ephType}" as ephemeral`, () => {
        const { broadcaster, activeSessions } = createHarness();
        const active = makeActive();
        activeSessions.set("k1", active);

        broadcaster.broadcast("k1", { type: ephType } as ServerMessage);
        expect(active.seq).toBe(0);
      });
    }
  });

  describe("durable broadcast", () => {
    it("increments seq monotonically across multiple broadcasts", () => {
      const { broadcaster, activeSessions } = createHarness();
      const active = makeActive();
      activeSessions.set("k1", active);

      broadcaster.broadcast("k1", { type: "agent_start" } as ServerMessage);
      broadcaster.broadcast("k1", { type: "tool_start", tool: "bash", args: {} } as ServerMessage);
      broadcaster.broadcast("k1", { type: "tool_end", tool: "bash" } as ServerMessage);

      expect(active.seq).toBe(3);
      expect(active.eventRing.currentSeq).toBe(3);
    });

    it("pushes events to the event ring", () => {
      const { broadcaster, activeSessions } = createHarness();
      const active = makeActive();
      activeSessions.set("k1", active);

      broadcaster.broadcast("k1", { type: "agent_start" } as ServerMessage);
      broadcaster.broadcast("k1", { type: "agent_end" } as ServerMessage);

      const events = active.eventRing.since(0);
      expect(events).toHaveLength(2);
      expect(events[0]!.event.type).toBe("agent_start");
      expect(events[1]!.event.type).toBe("agent_end");
    });

    it("fans out to all subscribers", () => {
      const { broadcaster, activeSessions } = createHarness();
      const active = makeActive();
      activeSessions.set("k1", active);

      const received1: ServerMessage[] = [];
      const received2: ServerMessage[] = [];
      active.subscribers.add((msg) => received1.push(msg));
      active.subscribers.add((msg) => received2.push(msg));

      broadcaster.broadcast("k1", { type: "agent_start" } as ServerMessage);

      expect(received1).toHaveLength(1);
      expect(received2).toHaveLength(1);
      expect(received1[0]!.seq).toBe(1);
    });

    it("is a no-op when session not found", () => {
      const { broadcaster, emitted } = createHarness();
      broadcaster.broadcast("nonexistent", { type: "agent_start" } as ServerMessage);
      expect(emitted).toHaveLength(0);
    });
  });

  describe("subscriber error handling", () => {
    it("catches and continues when a subscriber throws (durable)", () => {
      const { broadcaster, activeSessions } = createHarness();
      const active = makeActive();
      activeSessions.set("k1", active);

      const received: ServerMessage[] = [];
      active.subscribers.add(() => {
        throw new Error("subscriber boom");
      });
      active.subscribers.add((msg) => received.push(msg));

      // Should not throw
      broadcaster.broadcast("k1", { type: "agent_start" } as ServerMessage);

      // Second subscriber should still receive
      expect(received).toHaveLength(1);
    });

    it("catches and continues when a subscriber throws (ephemeral)", () => {
      const { broadcaster, activeSessions } = createHarness();
      const active = makeActive();
      activeSessions.set("k1", active);

      const received: ServerMessage[] = [];
      active.subscribers.add(() => {
        throw new Error("subscriber boom");
      });
      active.subscribers.add((msg) => received.push(msg));

      broadcaster.broadcast("k1", { type: "text_delta", delta: "x" } as ServerMessage);

      expect(received).toHaveLength(1);
    });
  });

  describe("subscribe / unsubscribe", () => {
    it("adds callback to subscriber set", () => {
      const { broadcaster, activeSessions } = createHarness();
      const active = makeActive();
      activeSessions.set("k1", active);

      const cb = vi.fn();
      broadcaster.subscribe("k1", cb);

      expect(active.subscribers.has(cb)).toBe(true);
    });

    it("returns unsubscribe function that removes callback", () => {
      const { broadcaster, activeSessions } = createHarness();
      const active = makeActive();
      activeSessions.set("k1", active);

      const cb = vi.fn();
      const unsub = broadcaster.subscribe("k1", cb);
      expect(active.subscribers.has(cb)).toBe(true);

      unsub();
      expect(active.subscribers.has(cb)).toBe(false);
    });

    it("returns no-op unsubscribe when session not found", () => {
      const { broadcaster } = createHarness();
      const unsub = broadcaster.subscribe("nonexistent", vi.fn());
      expect(() => unsub()).not.toThrow();
    });
  });

  describe("getCatchUp", () => {
    it("returns null when session not found", () => {
      const { broadcaster } = createHarness();
      expect(broadcaster.getCatchUp("nonexistent", 0)).toBeNull();
    });

    it("returns all events when sinceSeq is 0", () => {
      const { broadcaster, activeSessions } = createHarness();
      const active = makeActive();
      activeSessions.set("k1", active);

      broadcaster.broadcast("k1", { type: "agent_start" } as ServerMessage);
      broadcaster.broadcast("k1", { type: "agent_end" } as ServerMessage);

      const catchUp = broadcaster.getCatchUp("k1", 0);
      expect(catchUp).not.toBeNull();
      expect(catchUp!.events).toHaveLength(2);
      expect(catchUp!.currentSeq).toBe(2);
      expect(catchUp!.catchUpComplete).toBe(true);
    });

    it("returns only events after sinceSeq", () => {
      const { broadcaster, activeSessions } = createHarness();
      const active = makeActive();
      activeSessions.set("k1", active);

      broadcaster.broadcast("k1", { type: "agent_start" } as ServerMessage);
      broadcaster.broadcast("k1", { type: "tool_start", tool: "x", args: {} } as ServerMessage);
      broadcaster.broadcast("k1", { type: "tool_end", tool: "x" } as ServerMessage);

      const catchUp = broadcaster.getCatchUp("k1", 1);
      expect(catchUp!.events).toHaveLength(2);
      expect(catchUp!.events[0]!.type).toBe("tool_start");
    });

    it("returns catchUpComplete=false when ring cannot serve the requested seq", () => {
      const { broadcaster, activeSessions } = createHarness();
      // Use a tiny ring that will evict
      const active: BroadcastSessionState = {
        session: makeSession(),
        subscribers: new Set(),
        seq: 0,
        eventRing: new EventRing(2),
      };
      activeSessions.set("k1", active);

      broadcaster.broadcast("k1", { type: "agent_start" } as ServerMessage);
      broadcaster.broadcast("k1", { type: "tool_start", tool: "x", args: {} } as ServerMessage);
      broadcaster.broadcast("k1", { type: "tool_end", tool: "x" } as ServerMessage);
      // Ring now has [seq=2, seq=3] — seq=1 evicted

      const catchUp = broadcaster.getCatchUp("k1", 0);
      // canServe(0) → 0 >= 2-1=1 → false → catchUpComplete=false, events=[]
      expect(catchUp!.catchUpComplete).toBe(false);
      expect(catchUp!.events).toEqual([]);
      expect(catchUp!.currentSeq).toBe(3);
    });

    it("includes session in response", () => {
      const { broadcaster, activeSessions } = createHarness();
      const session = makeSession("s42");
      const active = makeActive(session);
      activeSessions.set("k1", active);

      const catchUp = broadcaster.getCatchUp("k1", 0);
      expect(catchUp!.session.id).toBe("s42");
    });
  });

  describe("getCurrentSeq", () => {
    it("returns 0 when session not found", () => {
      const { broadcaster } = createHarness();
      expect(broadcaster.getCurrentSeq("nonexistent")).toBe(0);
    });

    it("returns current seq for active session", () => {
      const { broadcaster, activeSessions } = createHarness();
      const active = makeActive();
      activeSessions.set("k1", active);

      broadcaster.broadcast("k1", { type: "agent_start" } as ServerMessage);
      expect(broadcaster.getCurrentSeq("k1")).toBe(1);
    });
  });

  describe("dirty session debounce", () => {
    it("saves dirty sessions after debounce timer", () => {
      const { broadcaster, activeSessions, saved } = createHarness(100);
      const active = makeActive();
      activeSessions.set("k1", active);

      broadcaster.markSessionDirty("k1");
      expect(saved).toHaveLength(0);

      vi.advanceTimersByTime(100);
      expect(saved).toHaveLength(1);
      expect(saved[0]!.id).toBe("sess-1");
    });

    it("coalesces multiple dirty marks into one save", () => {
      const { broadcaster, activeSessions, saved } = createHarness(100);
      const active = makeActive();
      activeSessions.set("k1", active);

      broadcaster.markSessionDirty("k1");
      broadcaster.markSessionDirty("k1");
      broadcaster.markSessionDirty("k1");

      vi.advanceTimersByTime(100);
      expect(saved).toHaveLength(1);
    });

    it("does not re-trigger timer if one is already pending", () => {
      const { broadcaster, activeSessions, saved } = createHarness(100);
      const active = makeActive();
      activeSessions.set("k1", active);

      broadcaster.markSessionDirty("k1");
      vi.advanceTimersByTime(50);
      broadcaster.markSessionDirty("k1"); // should not reset timer
      vi.advanceTimersByTime(50); // total 100ms from first mark

      expect(saved).toHaveLength(1);
    });

    it("saves multiple dirty sessions in one flush", () => {
      const { broadcaster, activeSessions, saved } = createHarness(100);
      activeSessions.set("k1", makeActive(makeSession("s1")));
      activeSessions.set("k2", makeActive(makeSession("s2")));

      broadcaster.markSessionDirty("k1");
      broadcaster.markSessionDirty("k2");

      vi.advanceTimersByTime(100);
      expect(saved).toHaveLength(2);
      const ids = saved.map((s) => s.id).sort();
      expect(ids).toEqual(["s1", "s2"]);
    });

    it("skips sessions that became inactive between mark and flush", () => {
      const { broadcaster, activeSessions, saved } = createHarness(100);
      activeSessions.set("k1", makeActive());

      broadcaster.markSessionDirty("k1");
      activeSessions.delete("k1"); // session ended

      vi.advanceTimersByTime(100);
      expect(saved).toHaveLength(0);
    });

    it("flushDirtySessions can be called manually before timer", () => {
      const { broadcaster, activeSessions, saved } = createHarness(100);
      activeSessions.set("k1", makeActive());

      broadcaster.markSessionDirty("k1");
      broadcaster.flushDirtySessions();

      expect(saved).toHaveLength(1);

      // Timer fire after manual flush should not double-save because
      // flushDirtySessions clears the set and nulls the timer reference.
      // However, the timer is still pending in the event loop!
      vi.advanceTimersByTime(100);
      // BUG PROBE: The setTimeout callback fires even after manual flush,
      // but since dirtySessions was cleared, flushDirtySessions inside the
      // callback will be a no-op. The timer IS leaked though — it fires
      // and calls flushDirtySessions on an empty set.
      expect(saved).toHaveLength(1); // no extra save
    });

    it("persistSessionNow removes from dirty set and saves immediately", () => {
      const { broadcaster, activeSessions, saved } = createHarness(100);
      const session = makeSession("s1");
      activeSessions.set("k1", makeActive(session));

      broadcaster.markSessionDirty("k1");
      broadcaster.persistSessionNow("k1", session);

      expect(saved).toHaveLength(1);

      // Timer fires but k1 was removed from dirty set
      vi.advanceTimersByTime(100);
      expect(saved).toHaveLength(1); // no double save
    });
  });
});
