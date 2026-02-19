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

function makeSession(status: Session["status"] = "ready"): Session {
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
} {
  const stdinWrite = vi.fn();
  const process = {
    stdin: {
      write: stdinWrite,
      writable: true,
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
  getModelThinkingLevelPreference: ReturnType<typeof vi.fn>;
  setModelThinkingLevelPreference: ReturnType<typeof vi.fn>;
} {
  const addSessionMessage = vi.fn();
  const thinkingLevelByModel = new Map<string, string>();

  const getModelThinkingLevelPreference = vi.fn((modelId: string) => {
    return thinkingLevelByModel.get(modelId);
  });

  const setModelThinkingLevelPreference = vi.fn(
    (modelId: string, level: string) => {
      thinkingLevelByModel.set(modelId, level);
    },
  );

  const storage = {
    getConfig: () => TEST_CONFIG,
    saveSession: vi.fn(),
    addSessionMessage,
    getModelThinkingLevelPreference,
    setModelThinkingLevelPreference,
    getWorkspace: vi.fn(() => undefined),
    saveWorkspace: vi.fn(),
  } as unknown as Storage;

  const gate = {
    destroySessionSocket: vi.fn(),
  } as unknown as GateServer;

  const manager = new SessionManager(storage, gate);

  // Keep tests deterministic — we don't need idle timer behavior here.
  (manager as { resetIdleTimer: (key: string) => void }).resetIdleTimer = () => {};

  const { process, stdinWrite } = makeProcessStub();
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
    guardCheckScheduled: true,
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
    session,
    stdinWrite,
    addSessionMessage,
    getModelThinkingLevelPreference,
    setModelThinkingLevelPreference,
  };
}

function asTurnAcks(events: ServerMessage[]): Array<Extract<ServerMessage, { type: "turn_ack" }>> {
  return events.filter(
    (event): event is Extract<ServerMessage, { type: "turn_ack" }> => event.type === "turn_ack",
  );
}

function asRpcResults(events: ServerMessage[]): Array<Extract<ServerMessage, { type: "rpc_result" }>> {
  return events.filter(
    (event): event is Extract<ServerMessage, { type: "rpc_result" }> => event.type === "rpc_result",
  );
}

function asStateEvents(events: ServerMessage[]): Array<Extract<ServerMessage, { type: "state" }>> {
  return events.filter(
    (event): event is Extract<ServerMessage, { type: "state" }> => event.type === "state",
  );
}

describe("turn delivery idempotency", () => {
  it("dedupes duplicate prompt retries by clientTurnId", async () => {
    const { manager, events, stdinWrite, addSessionMessage, session } = makeManagerHarness("ready");

    await manager.sendPrompt("s1", "hello", {
      clientTurnId: "turn-1",
      requestId: "req-1",
      timestamp: 1,
    });

    await manager.sendPrompt("s1", "hello", {
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

    await manager.sendPrompt("s1", "hello", {
      clientTurnId: "turn-1",
      requestId: "req-1",
      timestamp: 1,
    });

    await expect(
      manager.sendPrompt("s1", "different payload", {
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
    const key = "s1";

    await manager.sendPrompt("s1", "hello", {
      clientTurnId: "turn-1",
      requestId: "req-1",
      timestamp: 1,
    });

    const dispatchedDuplicateReqIds: string[] = [];
    for (let i = 2; i <= 12; i += 1) {
      const requestId = `req-${i}`;
      dispatchedDuplicateReqIds.push(requestId);
      await manager.sendPrompt("s1", "hello", {
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
      await manager.sendPrompt("s1", "hello", {
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
    const key = "s1";

    await manager.sendPrompt("s1", "hello", {
      clientTurnId: "turn-1",
      requestId: "req-1",
      timestamp: 1,
    });

    (manager as unknown as { handleRpcLine: (sessionKey: string, line: string) => void }).handleRpcLine(
      key,
      JSON.stringify({ type: "agent_start" }),
    );

    await manager.sendPrompt("s1", "hello", {
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

  it("refreshes and persists pi state after fork rpc succeeds", async () => {
    const { manager, events, session } = makeManagerHarness("ready");

    const saveSession = vi.spyOn(manager as unknown as { persistSessionNow: (key: string, session: Session) => void }, "persistSessionNow");

    const sendRpcCommandAsync = vi.fn(async (_key: string, command: Record<string, unknown>) => {
      if (command.type === "fork") {
        return { text: "forked", cancelled: false };
      }

      if (command.type === "get_state") {
        return {
          sessionFile: "/tmp/child.jsonl",
          sessionId: "pi-child-uuid",
        };
      }

      throw new Error(`unexpected command: ${String(command.type)}`);
    });

    (manager as unknown as { sendRpcCommandAsync: typeof sendRpcCommandAsync }).sendRpcCommandAsync = sendRpcCommandAsync;

    await manager.forwardRpcCommand("s1",
      { type: "fork", entryId: "msg-123" },
      "req-fork-1",
    );

    expect(sendRpcCommandAsync).toHaveBeenNthCalledWith(
      1,
      "s1",
      expect.objectContaining({ type: "fork", entryId: "msg-123" }),
      30_000,
    );

    expect(sendRpcCommandAsync).toHaveBeenNthCalledWith(
      2,
      "s1",
      expect.objectContaining({ type: "get_state" }),
      8_000,
    );

    expect(session.piSessionFile).toBe("/tmp/child.jsonl");
    expect(session.piSessionId).toBe("pi-child-uuid");
    expect(session.piSessionFiles).toEqual(["/tmp/child.jsonl"]);

    expect(saveSession).toHaveBeenCalled();

    const rpcResult = asRpcResults(events).find((event) => event.command === "fork");
    expect(rpcResult?.success).toBe(true);
    expect(rpcResult?.requestId).toBe("req-fork-1");

    const stateEvent = asStateEvents(events).at(-1);
    expect(stateEvent?.session.piSessionFile).toBe("/tmp/child.jsonl");
    expect(stateEvent?.session.piSessionId).toBe("pi-child-uuid");
  });

  it("persists thinking preference after set_thinking_level", async () => {
    const {
      manager,
      session,
      events,
      setModelThinkingLevelPreference,
    } = makeManagerHarness("ready");

    session.model = "anthropic/claude-sonnet-4-0";

    const sendRpcCommandAsync = vi.fn(async (_key: string, command: Record<string, unknown>) => {
      if (command.type === "set_thinking_level") {
        return {};
      }

      throw new Error(`unexpected command: ${String(command.type)}`);
    });

    (manager as unknown as { sendRpcCommandAsync: typeof sendRpcCommandAsync }).sendRpcCommandAsync = sendRpcCommandAsync;

    await manager.forwardRpcCommand("s1",
      { type: "set_thinking_level", level: "high" },
      "req-thinking-1",
    );

    expect(session.thinkingLevel).toBe("high");
    expect(setModelThinkingLevelPreference).toHaveBeenCalledWith(
      
      "anthropic/claude-sonnet-4-0",
      "high",
    );

    const stateEvent = asStateEvents(events).at(-1);
    expect(stateEvent?.session.thinkingLevel).toBe("high");
  });

  it("applies remembered model thinking after set_model", async () => {
    const {
      manager,
      session,
      events,
      getModelThinkingLevelPreference,
      setModelThinkingLevelPreference,
    } = makeManagerHarness("ready");

    getModelThinkingLevelPreference.mockImplementation((modelId: string) => {
      if (modelId === "anthropic/claude-sonnet-4-0") {
        return "minimal";
      }
      return undefined;
    });

    const sendRpcCommandAsync = vi.fn(async (_key: string, command: Record<string, unknown>) => {
      if (command.type === "set_model") {
        return { provider: "anthropic", id: "claude-sonnet-4-0" };
      }

      if (command.type === "set_thinking_level") {
        expect(command.level).toBe("minimal");
        return {};
      }

      if (command.type === "get_state") {
        return {
          model: { provider: "anthropic", id: "claude-sonnet-4-0" },
          thinkingLevel: "minimal",
        };
      }

      throw new Error(`unexpected command: ${String(command.type)}`);
    });

    (manager as unknown as { sendRpcCommandAsync: typeof sendRpcCommandAsync }).sendRpcCommandAsync = sendRpcCommandAsync;

    await manager.forwardRpcCommand("s1",
      { type: "set_model", provider: "anthropic", modelId: "claude-sonnet-4-0" },
      "req-model-1",
    );

    expect(sendRpcCommandAsync).toHaveBeenNthCalledWith(
      1,
      "s1",
      expect.objectContaining({ type: "set_model", provider: "anthropic", modelId: "claude-sonnet-4-0" }),
      30_000,
    );

    expect(sendRpcCommandAsync).toHaveBeenNthCalledWith(
      2,
      "s1",
      expect.objectContaining({ type: "set_thinking_level", level: "minimal" }),
      8_000,
    );

    expect(sendRpcCommandAsync).toHaveBeenNthCalledWith(
      3,
      "s1",
      expect.objectContaining({ type: "get_state" }),
      8_000,
    );

    expect(session.model).toBe("anthropic/claude-sonnet-4-0");
    expect(session.thinkingLevel).toBe("minimal");
    expect(setModelThinkingLevelPreference).toHaveBeenCalledWith(
      
      "anthropic/claude-sonnet-4-0",
      "minimal",
    );

    const stateEvent = asStateEvents(events).at(-1);
    expect(stateEvent?.session.model).toBe("anthropic/claude-sonnet-4-0");
    expect(stateEvent?.session.thinkingLevel).toBe("minimal");
  });

  it("prefixes provider on nested model IDs from get_state (e.g. openrouter/z.ai/glm-5)", async () => {
    const { manager, session, events } = makeManagerHarness("ready");

    // Simulate pi reporting a nested-provider model via get_state.
    // The model id contains a slash (z.ai/glm-5) but the provider is "openrouter".
    const sendRpcCommandAsync = vi.fn(async (_key: string, command: Record<string, unknown>) => {
      if (command.type === "set_model") {
        return { provider: "openrouter", id: "z.ai/glm-5" };
      }
      if (command.type === "get_state") {
        return {
          model: { provider: "openrouter", id: "z.ai/glm-5" },
        };
      }
      return {};
    });

    (manager as unknown as { sendRpcCommandAsync: typeof sendRpcCommandAsync }).sendRpcCommandAsync = sendRpcCommandAsync;

    await manager.forwardRpcCommand("s1",
      { type: "set_model", provider: "openrouter", modelId: "z.ai/glm-5" },
      "req-nested-1",
    );

    // The session model must include the provider prefix, not just "z.ai/glm-5"
    expect(session.model).toBe("openrouter/z.ai/glm-5");

    const stateEvent = asStateEvents(events).at(-1);
    expect(stateEvent?.session.model).toBe("openrouter/z.ai/glm-5");
  });

  it("does not double-prefix when model id already starts with provider", async () => {
    const { manager, session, events } = makeManagerHarness("ready");

    const sendRpcCommandAsync = vi.fn(async (_key: string, command: Record<string, unknown>) => {
      if (command.type === "set_model") {
        return { provider: "anthropic", id: "claude-sonnet-4-0" };
      }
      if (command.type === "get_state") {
        return {
          model: { provider: "anthropic", id: "claude-sonnet-4-0" },
        };
      }
      return {};
    });

    (manager as unknown as { sendRpcCommandAsync: typeof sendRpcCommandAsync }).sendRpcCommandAsync = sendRpcCommandAsync;

    await manager.forwardRpcCommand("s1",
      { type: "set_model", provider: "anthropic", modelId: "claude-sonnet-4-0" },
      "req-simple-1",
    );

    // Must be "anthropic/claude-sonnet-4-0", not "anthropic/anthropic/claude-sonnet-4-0"
    expect(session.model).toBe("anthropic/claude-sonnet-4-0");
  });
});
