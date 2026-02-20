import type { ChildProcess } from "node:child_process";
import { describe, expect, it, vi } from "vitest";
import { EventRing } from "../src/event-ring.js";
import { SessionManager } from "../src/sessions.js";
import { TurnDedupeCache } from "../src/turn-cache.js";
import type { GateServer } from "../src/gate.js";
import type { Storage } from "../src/storage.js";
import type { ServerConfig, ServerMessage, Session } from "../src/types.js";

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

type TestActiveSession = {
  session: Session;
  process: ChildProcess;
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

function makeProcessStub(): {
  process: ChildProcess;
  stdinWrite: ReturnType<typeof vi.fn>;
  kill: ReturnType<typeof vi.fn>;
} {
  const stdinWrite = vi.fn();
  const proc = {
    stdin: {
      write: stdinWrite,
      writable: true,
    },
    killed: false,
  } as unknown as ChildProcess;

  const kill = vi.fn(() => {
    (proc as { killed: boolean }).killed = true;
    return true;
  });
  (proc as { kill: typeof kill }).kill = kill;

  return { process: proc, stdinWrite, kill };
}

function makeManagerHarness(status: Session["status"] = "busy"): {
  manager: SessionManager;
  events: ServerMessage[];
  active: TestActiveSession;
  stdinWrite: ReturnType<typeof vi.fn>;
  kill: ReturnType<typeof vi.fn>;
} {
  const storage = {
    getConfig: () => TEST_CONFIG,
    saveSession: vi.fn(),
    getWorkspace: vi.fn(() => undefined),
  } as unknown as Storage;

  const gate = {
    destroySessionSocket: vi.fn(),
  } as unknown as GateServer;

  const manager = new SessionManager(storage, gate);

  // Keep tests deterministic — we don't need idle timer behavior here.
  (manager as { resetIdleTimer: (key: string) => void }).resetIdleTimer = () => {};

  const { process, stdinWrite, kill } = makeProcessStub();
  const session = makeSession(status);

  const active = {
    session,
    process,
    workspaceId: "w1",
    subscribers: new Set<(msg: ServerMessage) => void>(),
    pendingResponses: new Map(),
    pendingUIRequests: new Map(),
    partialResults: new Map(),
    streamedAssistantText: "",
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

  return {
    manager,
    events,
    active: { session, process },
    stdinWrite,
    kill,
  };
}

describe("stop lifecycle", () => {
  it("dedupes duplicate stop taps while graceful stop is pending", async () => {
    const { manager, events, stdinWrite, active } = makeManagerHarness("busy");

    await manager.sendAbort("s1");
    await manager.sendAbort("s1");

    expect(stdinWrite).toHaveBeenCalledTimes(1);
    const stopRequested = events.filter((event) => event.type === "stop_requested");
    expect(stopRequested).toHaveLength(1);
    expect(active.session.status).toBe("stopping");
  });

  it("escalates abort timeout to SIGINT then gives up without killing session", async () => {
    vi.useFakeTimers();
    try {
      const { manager, events, kill, active } = makeManagerHarness("busy");

      await manager.sendAbort("s1");

      // Phase 1: after stopAbortTimeoutMs, sends SIGINT (not SIGTERM)
      vi.advanceTimersByTime((manager as unknown as { stopAbortTimeoutMs: number }).stopAbortTimeoutMs);

      expect(kill).toHaveBeenCalledTimes(1);
      expect(kill).toHaveBeenCalledWith("SIGINT");

      // Should broadcast a stop_requested from server about the interrupt
      const interruptRequested = events.find(
        (event): event is Extract<ServerMessage, { type: "stop_requested" }> =>
          event.type === "stop_requested" && event.source === "server",
      );
      expect(interruptRequested).toBeTruthy();

      // Session should still be alive
      expect(manager.isActive("s1")).toBe(true);
      expect(events.some((event) => event.type === "session_ended")).toBe(false);

      // Phase 2: after stopAbortSigintTimeoutMs, gives up but keeps session alive
      vi.advanceTimersByTime(
        (manager as unknown as { stopAbortSigintTimeoutMs: number }).stopAbortSigintTimeoutMs,
      );

      const failed = events.find(
        (event): event is Extract<ServerMessage, { type: "stop_failed" }> =>
          event.type === "stop_failed",
      );
      expect(failed).toBeTruthy();

      // Session stays alive — user can send another message or stop session explicitly
      expect(manager.isActive("s1")).toBe(true);
      expect(events.some((event) => event.type === "session_ended")).toBe(false);
      expect(active.session.status).toBe("busy"); // restored from "stopping"
    } finally {
      vi.clearAllTimers();
      vi.useRealTimers();
    }
  });

  it("abort succeeds after SIGINT before second timeout", async () => {
    vi.useFakeTimers();
    try {
      const { manager, events, kill } = makeManagerHarness("busy");
      const key = "s1";

      await manager.sendAbort("s1");

      // Phase 1 timeout: sends SIGINT
      vi.advanceTimersByTime((manager as unknown as { stopAbortTimeoutMs: number }).stopAbortTimeoutMs);
      expect(kill).toHaveBeenCalledWith("SIGINT");

      // Pi responds with agent_end after SIGINT interrupts the tool
      (manager as unknown as { handleRpcLine: (key: string, line: string) => void }).handleRpcLine(
        key,
        JSON.stringify({ type: "agent_end" }),
      );

      const confirmed = events.filter((event) => event.type === "stop_confirmed");
      expect(confirmed).toHaveLength(1);
      expect(manager.isActive("s1")).toBe(true);

      // Phase 2 timeout should be a no-op since abort already succeeded
      vi.advanceTimersByTime(
        (manager as unknown as { stopAbortSigintTimeoutMs: number }).stopAbortSigintTimeoutMs,
      );

      expect(events.some((event) => event.type === "stop_failed")).toBe(false);
      expect(events.some((event) => event.type === "session_ended")).toBe(false);
    } finally {
      vi.clearAllTimers();
      vi.useRealTimers();
    }
  });

  it("confirms graceful stop after tool loop drains to agent_end", async () => {
    const { manager, events, active } = makeManagerHarness("busy");
    const key = "s1";

    await manager.sendAbort("s1");

    (manager as unknown as { handleRpcLine: (key: string, line: string) => void }).handleRpcLine(
      key,
      JSON.stringify({
        type: "tool_execution_start",
        toolName: "bash",
        args: { command: "echo test" },
        toolCallId: "tc-1",
      }),
    );

    expect(active.session.status).toBe("stopping");

    (manager as unknown as { handleRpcLine: (key: string, line: string) => void }).handleRpcLine(
      key,
      JSON.stringify({ type: "agent_end" }),
    );

    const confirmed = events.filter((event) => event.type === "stop_confirmed");
    expect(confirmed).toHaveLength(1);
    expect(active.session.status).toBe("ready");
    expect(events.some((event) => event.type === "stop_failed")).toBe(false);
  });
});
