
import { describe, expect, it, vi } from "vitest";
import { EventRing } from "../src/event-ring.js";
import { SessionManager } from "../src/sessions.js";
import { TurnDedupeCache } from "../src/turn-cache.js";
import type { GateServer } from "../src/gate.js";
import type { Storage } from "../src/storage.js";
import type { ServerConfig, ServerMessage, Session } from "../src/types.js";
import { makeSdkBackendStub } from "./sdk-backend.helpers.js";

const TEST_CONFIG: ServerConfig = {
  port: 7749,
  host: "127.0.0.1",
  dataDir: "/tmp/oppi-server-tests",
  defaultModel: "anthropic/claude-sonnet-4-0",
  sessionTimeout: 600_000,
  sessionIdleTimeoutMs: 600_000,
  workspaceIdleTimeoutMs: 1_800_000,
  maxSessionsPerWorkspace: 3,
  maxSessionsGlobal: 5,
};

function makeSession(status: Session["status"] = "busy"): Session {
  const now = Date.now();
  return {
    id: "s1",
    workspaceId: "w1",
    status,
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
  };
}

function makeManagerHarness(status: Session["status"] = "busy") {
  const storage = {
    getConfig: () => TEST_CONFIG,
    saveSession: vi.fn(),
    getWorkspace: vi.fn(() => undefined),
  } as unknown as Storage;

  const gate = {
    destroySessionGuard: vi.fn(),
  } as unknown as GateServer;

  const manager = new SessionManager(storage, gate);

  (manager as { resetIdleTimer: (key: string) => void }).resetIdleTimer = () => {};

  const { sdkBackend, abort, dispose } = makeSdkBackendStub();
  const session = makeSession(status);

  const active = {
    session,
    sdkBackend,
    workspaceId: "w1",
    subscribers: new Set<(msg: ServerMessage) => void>(),
    pendingUIRequests: new Map(),
    partialResults: new Map(),
    streamedAssistantText: "",
    hasStreamedThinking: false,
    turnCache: new TurnDedupeCache(),
    pendingTurnStarts: [],
    seq: 0,
    eventRing: new EventRing(),
  };

  const key = session.id;
  ((manager as unknown as { active: Map<string, unknown> }).active).set(key, active);

  const events: ServerMessage[] = [];
  manager.subscribe(session.id, (msg) => {
    events.push(msg);
  });

  return { manager, events, session, sdkBackend, abort, dispose };
}

describe("stop lifecycle", () => {
  it("dedupes duplicate stop taps while graceful stop is pending", async () => {
    const { manager, events, abort, session } = makeManagerHarness("busy");
    const active = { session };

    await manager.sendAbort("s1");
    await manager.sendAbort("s1");

    expect(abort).toHaveBeenCalledTimes(1);
    const stopRequested = events.filter((event) => event.type === "stop_requested");
    expect(stopRequested).toHaveLength(1);
    expect(active.session.status).toBe("stopping");
  });

  it("escalates abort timeout to second abort then gives up without killing session", async () => {
    vi.useFakeTimers();
    try {
      const { manager, events, abort, session } = makeManagerHarness("busy");

      await manager.sendAbort("s1");

      // Phase 1: after stopAbortTimeoutMs, calls abort() again
      vi.advanceTimersByTime((manager as unknown as { stopAbortTimeoutMs: number }).stopAbortTimeoutMs);

      // Initial abort + escalation abort
      expect(abort).toHaveBeenCalledTimes(2);

      // Should broadcast a stop_requested from server about the interrupt
      const interruptRequested = events.find(
        (event): event is Extract<ServerMessage, { type: "stop_requested" }> =>
          event.type === "stop_requested" && event.source === "server",
      );
      expect(interruptRequested).toBeTruthy();

      // Session should still be alive
      expect(manager.isActive("s1")).toBe(true);
      expect(events.some((event) => event.type === "session_ended")).toBe(false);

      // Phase 2: after stopAbortRetryTimeoutMs, gives up but keeps session alive
      vi.advanceTimersByTime(
        (manager as unknown as { stopAbortRetryTimeoutMs: number }).stopAbortRetryTimeoutMs,
      );

      const failed = events.find(
        (event): event is Extract<ServerMessage, { type: "stop_failed" }> =>
          event.type === "stop_failed",
      );
      expect(failed).toBeTruthy();

      // Session stays alive — user can send another message or stop session explicitly
      expect(manager.isActive("s1")).toBe(true);
      expect(events.some((event) => event.type === "session_ended")).toBe(false);
      expect(session.status).toBe("busy"); // restored from "stopping"
    } finally {
      vi.clearAllTimers();
      vi.useRealTimers();
    }
  });

  it("abort succeeds after escalation before second timeout", async () => {
    vi.useFakeTimers();
    try {
      const { manager, events, abort } = makeManagerHarness("busy");
      const key = "s1";

      await manager.sendAbort("s1");

      // Phase 1 timeout: calls abort() again
      vi.advanceTimersByTime((manager as unknown as { stopAbortTimeoutMs: number }).stopAbortTimeoutMs);
      expect(abort).toHaveBeenCalledTimes(2);

      // Agent responds with agent_end after abort interrupts the tool
      (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
        key,
        { type: "agent_end" },
      );

      const confirmed = events.filter((event) => event.type === "stop_confirmed");
      expect(confirmed).toHaveLength(1);
      expect(manager.isActive("s1")).toBe(true);

      // Phase 2 timeout should be a no-op since abort already succeeded
      vi.advanceTimersByTime(
        (manager as unknown as { stopAbortRetryTimeoutMs: number }).stopAbortRetryTimeoutMs,
      );

      expect(events.some((event) => event.type === "stop_failed")).toBe(false);
      expect(events.some((event) => event.type === "session_ended")).toBe(false);
    } finally {
      vi.clearAllTimers();
      vi.useRealTimers();
    }
  });

  it("confirms graceful stop after tool loop drains to agent_end", async () => {
    const { manager, events, session } = makeManagerHarness("busy");
    const key = "s1";

    await manager.sendAbort("s1");

    (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
      key,
      {
        type: "tool_execution_start",
        toolName: "bash",
        args: { command: "echo test" },
        toolCallId: "tc-1",
      },
    );

    expect(session.status).toBe("stopping");

    (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
      key,
      { type: "agent_end" },
    );

    const confirmed = events.filter((event) => event.type === "stop_confirmed");
    expect(confirmed).toHaveLength(1);
    expect(session.status).toBe("ready");
    expect(events.some((event) => event.type === "stop_failed")).toBe(false);
  });
});
