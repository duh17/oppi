import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { LiveActivityBridge } from "../src/live-activity.js";
import type { PushClient } from "../src/push.js";
import type { Storage } from "../src/storage.js";
import type { Session } from "../src/types.js";
import type { SessionBroadcastEvent } from "../src/sessions.js";

// ─── Helpers ───

function makeSession(overrides: Partial<Session> = {}): Session {
  const now = Date.now();
  return {
    id: "s1",
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

function makePush(): PushClient & {
  updates: Array<{
    token: string;
    contentState: Record<string, unknown>;
    staleDate?: number;
    priority: number;
  }>;
  ends: Array<{ token: string; contentState: Record<string, unknown>; priority: number }>;
} {
  const updates: Array<{
    token: string;
    contentState: Record<string, unknown>;
    staleDate?: number;
    priority: number;
  }> = [];
  const ends: Array<{ token: string; contentState: Record<string, unknown>; priority: number }> =
    [];
  return {
    updates,
    ends,
    sendSessionEventPush: vi.fn(async () => true),
    sendLiveActivityUpdate: vi.fn(
      async (
        token: string,
        contentState: Record<string, unknown>,
        staleDate?: number,
        priority: 5 | 10 = 5,
      ) => {
        updates.push({ token, contentState, staleDate, priority });
        return true;
      },
    ),
    endLiveActivity: vi.fn(
      async (
        token: string,
        contentState: Record<string, unknown>,
        _dismissalDate?: number,
        priority: 5 | 10 = 10,
      ) => {
        ends.push({ token, contentState, priority });
        return true;
      },
    ),
    shutdown: vi.fn(),
  } as unknown as PushClient & {
    updates: Array<{
      token: string;
      contentState: Record<string, unknown>;
      staleDate?: number;
      priority: number;
    }>;
    ends: Array<{ token: string; contentState: Record<string, unknown>; priority: number }>;
  };
}

function makeStorageStub(
  liveActivityToken: string | null = "la-token",
  sessions: Session[] = [],
): Storage & { clearedToken: boolean } {
  let token = liveActivityToken;
  const stub = {
    clearedToken: false,
    getLiveActivityToken: vi.fn(() => token ?? undefined),
    setLiveActivityToken: vi.fn((t: string | null) => {
      token = t;
      if (t === null) stub.clearedToken = true;
    }),
    getSession: vi.fn((id: string) => sessions.find((s) => s.id === id)),
    listSessions: vi.fn(() => sessions),
  };
  return stub as unknown as Storage & { clearedToken: boolean };
}

function makeBridge(
  opts: {
    push?: ReturnType<typeof makePush>;
    storage?: ReturnType<typeof makeStorageStub>;
  } = {},
) {
  const push = opts.push ?? makePush();
  const storage = opts.storage ?? makeStorageStub();
  const bridge = new LiveActivityBridge(push, storage);
  return { bridge, push, storage };
}

function event(
  type: string,
  sessionId = "s1",
  extra: Record<string, unknown> = {},
): SessionBroadcastEvent {
  const base: Record<string, unknown> = { type, ...extra };
  if (type === "state" && !("session" in extra)) {
    base.session = makeSession({ status: "ready" });
  }
  return {
    sessionId,
    event: base,
    durable: false,
  } as unknown as SessionBroadcastEvent;
}

// ─── Tests ───

describe("LiveActivityBridge", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe("event mapping", () => {
    it("maps agent_start to busy status", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("agent_start"));
      vi.advanceTimersByTime(800);

      expect(push.updates).toHaveLength(1);
      expect(push.updates[0].contentState.status).toBe("busy");
      expect(push.updates[0].contentState.lastEvent).toBe("Agent started");
    });

    it("keeps agent_end busy until agent_settled", () => {
      const storage = makeStorageStub("la-token", [makeSession({ status: "busy" })]);
      const { bridge, push } = makeBridge({ storage });

      bridge.handleSessionEvent(event("agent_end"));
      vi.advanceTimersByTime(800);

      expect(push.updates[0].contentState.status).toBe("busy");
      expect(push.updates[0].contentState.activeTool).toBeNull();
      expect(push.updates[0].contentState.lastEvent).toBe("Agent run finished");

      bridge.handleSessionEvent(event("agent_settled"));
      vi.advanceTimersByTime(800);

      expect(push.updates[1].contentState.status).toBe("ready");
      expect(push.updates[1].contentState.lastEvent).toBe("Agent finished");
    });

    it("maps tool_start to busy with tool name", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("tool_start", "s1", { tool: "bash" }));
      vi.advanceTimersByTime(800);

      expect(push.updates[0].contentState.status).toBe("busy");
      expect(push.updates[0].contentState.activeTool).toBe("bash");
    });

    it("maps tool_end to null activeTool", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("tool_end", "s1", { tool: "bash" }));
      vi.advanceTimersByTime(800);

      expect(push.updates[0].contentState.activeTool).toBeNull();
    });

    it("maps stop_requested to stopping", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("stop_requested"));
      vi.advanceTimersByTime(800);

      expect(push.updates[0].contentState.status).toBe("stopping");
    });

    it("maps stop_confirmed to ready", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("stop_confirmed"));
      vi.advanceTimersByTime(800);

      expect(push.updates[0].contentState.status).toBe("ready");
    });

    it("maps stop_failed to error with priority 10", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("stop_failed"));
      vi.advanceTimersByTime(800);

      expect(push.updates[0].contentState.status).toBe("error");
      expect(push.updates[0].priority).toBe(10);
    });

    it("maps extension UI requests with priority 10", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(
        event("extension_ui_request", "s1", {
          id: "ui-1",
          method: "select",
          title: "Permission required",
        }),
      );
      vi.advanceTimersByTime(800);

      expect(push.updates[0].contentState.lastEvent).toBe("Permission required");
      expect(push.updates[0].priority).toBe(10);
    });

    it("maps error to error status (non-retry)", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("error", "s1", { error: "model crashed" }));
      vi.advanceTimersByTime(800);

      expect(push.updates[0].contentState.status).toBe("error");
    });

    it("ignores retry errors", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("error", "s1", { error: "Retrying (3/5)" }));
      vi.advanceTimersByTime(800);

      expect(push.updates).toHaveLength(0);
    });

    it("maps session_ended to end with reason", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("session_ended", "s1", { reason: "user quit" }));
      vi.advanceTimersByTime(800);

      expect(push.ends).toHaveLength(1);
      expect(push.ends[0].contentState.status).toBe("stopped");
      expect(push.ends[0].contentState.lastEvent).toBe("user quit");
    });

    it("maps state event to session status label", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(
        event("state", "s1", {
          session: makeSession({ status: "busy" }),
        }),
      );
      vi.advanceTimersByTime(800);

      expect(push.updates[0].contentState.status).toBe("busy");
      expect(push.updates[0].contentState.lastEvent).toBe("Working");
    });

    it("ignores unknown event types", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("future_event_v99"));
      vi.advanceTimersByTime(800);

      expect(push.updates).toHaveLength(0);
      expect(push.ends).toHaveLength(0);
    });
  });

  describe("debouncing", () => {
    it("coalesces rapid events into one push", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("agent_start"));
      bridge.handleSessionEvent(event("tool_start", "s1", { tool: "bash" }));
      bridge.handleSessionEvent(event("tool_end", "s1", { tool: "bash" }));

      vi.advanceTimersByTime(800);

      // Only one push sent (coalesced)
      expect(push.updates).toHaveLength(1);
    });

    it("preserves highest priority across merged events", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("agent_start")); // priority 5
      bridge.handleSessionEvent(event("stop_failed")); // priority 10

      vi.advanceTimersByTime(800);

      expect(push.updates[0].priority).toBe(10);
    });

    it("last-writer-wins for status and lastEvent", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("agent_start")); // status=busy
      bridge.handleSessionEvent(event("stop_confirmed")); // status=ready

      vi.advanceTimersByTime(800);

      expect(push.updates[0].contentState.status).toBe("ready");
      expect(push.updates[0].contentState.lastEvent).toBe("Stop confirmed");
    });

    it("does not send before debounce window", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("agent_start"));
      vi.advanceTimersByTime(500);

      expect(push.updates).toHaveLength(0);
    });

    it("sends separate pushes for events after debounce window", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("agent_start"));
      vi.advanceTimersByTime(800);

      bridge.handleSessionEvent(event("agent_settled"));
      vi.advanceTimersByTime(800);

      expect(push.updates).toHaveLength(2);
      expect(push.updates[0].contentState.status).toBe("busy");
      expect(push.updates[1].contentState.status).toBe("ready");
    });
  });

  describe("content state", () => {
    it("computes elapsed seconds from session createdAt", () => {
      const session = makeSession({ id: "s1", createdAt: Date.now() - 120_000 });
      const storage = makeStorageStub("la-token", [session]);
      const { bridge, push } = makeBridge({ storage });

      bridge.handleSessionEvent(event("agent_start"));
      vi.advanceTimersByTime(800);

      expect(push.updates[0].contentState.elapsedSeconds).toBeGreaterThanOrEqual(120);
    });

    it("returns 0 elapsed when session not found", () => {
      const storage = makeStorageStub("la-token", []);
      const { bridge, push } = makeBridge({ storage });

      bridge.handleSessionEvent(event("agent_start", "missing-session"));
      vi.advanceTimersByTime(800);

      expect(push.updates[0].contentState.elapsedSeconds).toBe(0);
    });
  });

  describe("no-op when token absent", () => {
    it("does not push when no live activity token", () => {
      const storage = makeStorageStub(null);
      const { bridge, push } = makeBridge({ storage });

      bridge.handleSessionEvent(event("agent_start"));
      vi.advanceTimersByTime(800);

      expect(push.updates).toHaveLength(0);
    });
  });

  describe("end live activity", () => {
    it("calls endLiveActivity and clears token on success", async () => {
      const { bridge, push, storage } = makeBridge();

      bridge.handleSessionEvent(event("session_ended", "s1", { reason: "done" }));
      vi.advanceTimersByTime(800);

      expect(push.ends).toHaveLength(1);

      // Let the promise resolve
      await vi.advanceTimersByTimeAsync(0);
      expect(storage.clearedToken).toBe(true);
    });

    it("sticky end flag survives coalescing", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("agent_start"));
      bridge.handleSessionEvent(event("session_ended", "s1", { reason: "done" }));
      vi.advanceTimersByTime(800);

      // end flag sticks even though agent_start came first
      expect(push.ends).toHaveLength(1);
      expect(push.updates).toHaveLength(0);
    });
  });

  describe("shutdown", () => {
    it("clears pending state and timer", () => {
      const { bridge, push } = makeBridge();

      bridge.handleSessionEvent(event("agent_start"));
      bridge.shutdown();
      vi.advanceTimersByTime(800);

      expect(push.updates).toHaveLength(0);
    });

    it("is safe to call multiple times", () => {
      const { bridge } = makeBridge();
      bridge.shutdown();
      bridge.shutdown();
    });
  });
});
