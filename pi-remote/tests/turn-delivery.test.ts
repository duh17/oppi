import type { ChildProcess } from "node:child_process";
import { describe, expect, it, vi } from "vitest";
import { EventRing, SessionManager, TurnDedupeCache } from "../src/sessions.js";
import type { GateServer } from "../src/gate.js";
import type { SandboxManager } from "../src/sandbox.js";
import type { Storage } from "../src/storage.js";
import type { ServerConfig, ServerMessage, Session } from "../src/types.js";

const TEST_CONFIG: ServerConfig = {
  port: 7749,
  host: "127.0.0.1",
  dataDir: "/tmp/pi-remote-tests",
  defaultModel: "anthropic/claude-sonnet-4-0",
  sessionTimeout: 600_000,
  sessionIdleTimeoutMs: 600_000,
  workspaceIdleTimeoutMs: 1_800_000,
  maxSessionsPerWorkspace: 3,
  maxSessionsGlobal: 5,
};

function makeSession(status: Session["status"] = "ready"): Session {
  const now = Date.now();
  return {
    id: "s1",
    userId: "u1",
    workspaceId: "w1",
    status,
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
    runtime: "host",
  };
}

function makeProcessStub(): {
  process: ChildProcess;
  stdinWrite: ReturnType<typeof vi.fn>;
} {
  const stdinWrite = vi.fn();
  const process = {
    stdin: {
      write: stdinWrite,
    },
    killed: false,
  } as unknown as ChildProcess;

  return { process, stdinWrite };
}

function makeManagerHarness(status: Session["status"] = "ready"): {
  manager: SessionManager;
  events: ServerMessage[];
  session: Session;
  stdinWrite: ReturnType<typeof vi.fn>;
  addSessionMessage: ReturnType<typeof vi.fn>;
} {
  const addSessionMessage = vi.fn();

  const storage = {
    getConfig: () => TEST_CONFIG,
    saveSession: vi.fn(),
    addSessionMessage,
  } as unknown as Storage;

  const gate = {
    destroySessionSocket: vi.fn(),
  } as unknown as GateServer;

  const sandbox = {
    stopAll: vi.fn(async () => {}),
    stopWorkspaceContainer: vi.fn(async () => {}),
  } as unknown as SandboxManager;

  const manager = new SessionManager(storage, gate, sandbox);

  // Keep tests deterministic — we don't need idle timer behavior here.
  (manager as { resetIdleTimer: (key: string) => void }).resetIdleTimer = () => {};

  const { process, stdinWrite } = makeProcessStub();
  const session = makeSession(status);

  const active = {
    session,
    process,
    workspaceId: "w1",
    runtime: "host",
    subscribers: new Set<(msg: ServerMessage) => void>(),
    pendingResponses: new Map(),
    pendingUIRequests: new Map(),
    partialResults: new Map(),
    streamedAssistantText: "",
    turnCache: new TurnDedupeCache(),
    pendingTurnStarts: [],
    guardCheckScheduled: true,
    seq: 0,
    eventRing: new EventRing(),
  };

  const key = `${session.userId}/${session.id}`;
  ((manager as unknown as { active: Map<string, unknown> }).active).set(key, active);

  const events: ServerMessage[] = [];
  manager.subscribe(session.userId, session.id, (msg) => {
    events.push(msg);
  });

  return {
    manager,
    events,
    session,
    stdinWrite,
    addSessionMessage,
  };
}

function asTurnAcks(events: ServerMessage[]): Array<Extract<ServerMessage, { type: "turn_ack" }>> {
  return events.filter(
    (event): event is Extract<ServerMessage, { type: "turn_ack" }> => event.type === "turn_ack",
  );
}

describe("turn delivery idempotency", () => {
  it("dedupes duplicate prompt retries by clientTurnId", async () => {
    const { manager, events, stdinWrite, addSessionMessage, session } = makeManagerHarness("ready");

    await manager.sendPrompt("u1", "s1", "hello", {
      clientTurnId: "turn-1",
      requestId: "req-1",
      timestamp: 1,
    });

    await manager.sendPrompt("u1", "s1", "hello", {
      clientTurnId: "turn-1",
      requestId: "req-2",
      timestamp: 2,
    });

    expect(addSessionMessage).toHaveBeenCalledTimes(1);
    expect(stdinWrite).toHaveBeenCalledTimes(1);
    expect(session.messageCount).toBe(1);
    expect(session.lastMessage).toBe("hello");

    const turnAcks = asTurnAcks(events);
    expect(turnAcks).toHaveLength(3);

    const duplicateAck = turnAcks.find((ack) => ack.requestId === "req-2");
    expect(duplicateAck?.stage).toBe("dispatched");
    expect(duplicateAck?.duplicate).toBe(true);
  });

  it("rejects conflicting payload reuse for the same clientTurnId", async () => {
    const { manager, events, stdinWrite, addSessionMessage } = makeManagerHarness("ready");

    await manager.sendPrompt("u1", "s1", "hello", {
      clientTurnId: "turn-1",
      requestId: "req-1",
      timestamp: 1,
    });

    await expect(
      manager.sendPrompt("u1", "s1", "different payload", {
        clientTurnId: "turn-1",
        requestId: "req-2",
        timestamp: 2,
      }),
    ).rejects.toThrow("clientTurnId conflict: turn-1");

    expect(addSessionMessage).toHaveBeenCalledTimes(1);
    expect(stdinWrite).toHaveBeenCalledTimes(1);

    const turnAcks = asTurnAcks(events);
    expect(turnAcks).toHaveLength(2);
  });

  it("absorbs duplicate retry storms without duplicate persistence", async () => {
    const { manager, events, stdinWrite, addSessionMessage } = makeManagerHarness("ready");
    const key = "u1/s1";

    await manager.sendPrompt("u1", "s1", "hello", {
      clientTurnId: "turn-1",
      requestId: "req-1",
      timestamp: 1,
    });

    const dispatchedDuplicateReqIds: string[] = [];
    for (let i = 2; i <= 12; i += 1) {
      const requestId = `req-${i}`;
      dispatchedDuplicateReqIds.push(requestId);
      await manager.sendPrompt("u1", "s1", "hello", {
        clientTurnId: "turn-1",
        requestId,
        timestamp: i,
      });
    }

    expect(addSessionMessage).toHaveBeenCalledTimes(1);
    expect(stdinWrite).toHaveBeenCalledTimes(1);

    (manager as unknown as { handleRpcLine: (sessionKey: string, line: string) => void }).handleRpcLine(
      key,
      JSON.stringify({ type: "agent_start" }),
    );

    const startedDuplicateReqIds: string[] = [];
    for (let i = 13; i <= 20; i += 1) {
      const requestId = `req-${i}`;
      startedDuplicateReqIds.push(requestId);
      await manager.sendPrompt("u1", "s1", "hello", {
        clientTurnId: "turn-1",
        requestId,
        timestamp: i,
      });
    }

    expect(addSessionMessage).toHaveBeenCalledTimes(1);
    expect(stdinWrite).toHaveBeenCalledTimes(1);

    const duplicateAcks = asTurnAcks(events).filter((ack) => ack.duplicate);
    expect(duplicateAcks).toHaveLength(dispatchedDuplicateReqIds.length + startedDuplicateReqIds.length);

    for (const requestId of dispatchedDuplicateReqIds) {
      const ack = duplicateAcks.find((event) => event.requestId === requestId);
      expect(ack?.stage).toBe("dispatched");
    }

    for (const requestId of startedDuplicateReqIds) {
      const ack = duplicateAcks.find((event) => event.requestId === requestId);
      expect(ack?.stage).toBe("started");
    }
  });

  it("replays latest stage on duplicate retries after turn start", async () => {
    const { manager, events, stdinWrite } = makeManagerHarness("ready");
    const key = "u1/s1";

    await manager.sendPrompt("u1", "s1", "hello", {
      clientTurnId: "turn-1",
      requestId: "req-1",
      timestamp: 1,
    });

    (manager as unknown as { handleRpcLine: (sessionKey: string, line: string) => void }).handleRpcLine(
      key,
      JSON.stringify({ type: "agent_start" }),
    );

    await manager.sendPrompt("u1", "s1", "hello", {
      clientTurnId: "turn-1",
      requestId: "req-2",
      timestamp: 2,
    });

    expect(stdinWrite).toHaveBeenCalledTimes(1);

    const turnAcks = asTurnAcks(events);
    const duplicateAck = turnAcks.find((ack) => ack.requestId === "req-2");
    expect(duplicateAck?.stage).toBe("started");
    expect(duplicateAck?.duplicate).toBe(true);
  });
});
