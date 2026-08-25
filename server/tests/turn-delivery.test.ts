import { describe, expect, it, vi } from "vitest";
import { EventRing } from "../src/event-ring.js";
import { SessionManager } from "../src/sessions.js";
import { TurnDedupeCache } from "../src/turn-cache.js";
import type { Storage } from "../src/storage.js";
import type { ServerConfig, ServerMessage, Session } from "../src/types.js";
import { makeSdkBackendStub } from "./sdk-backend.helpers.js";
import { messagesOfType } from "./harness/ws-harness.js";

const TEST_CONFIG: ServerConfig = {
  port: 7749,
  host: "127.0.0.1",
  dataDir: "/tmp/oppi-server-tests",
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

function makeManagerHarness(status: Session["status"] = "ready"): {
  manager: SessionManager;
  events: ServerMessage[];
  session: Session;
  sdkBackend: ReturnType<typeof makeSdkBackendStub>["sdkBackend"];
  prompt: ReturnType<typeof vi.fn>;
} {
  const storage = {
    getConfig: () => TEST_CONFIG,
    getDataDir: vi.fn(() => TEST_CONFIG.dataDir),
    saveSession: vi.fn(),
    getWorkspace: vi.fn(() => undefined),
    saveWorkspace: vi.fn(),
  } as unknown as Storage;

  const manager = new SessionManager(storage);

  (manager as { resetIdleTimer: (key: string) => void }).resetIdleTimer = () => {};

  const { sdkBackend, prompt } = makeSdkBackendStub();
  const session = makeSession(status);

  const active = {
    session,
    sdkBackend,
    workspaceId: "w1",
    subscribers: new Set<(msg: ServerMessage) => void>(),
    pendingUIRequests: new Map(),
    partialResults: new Map(),
    streamedAssistantText: "",
    toolNames: new Map(),
    shellPreviewLastSent: new Map(),
    streamingToolUpdatesSeen: new Map(),
    turnCache: new TurnDedupeCache(),
    pendingTurnStarts: [],
    seq: 0,
    eventRing: new EventRing(),
  };

  const key = session.id;
  (manager as unknown as { active: Map<string, unknown> }).active.set(key, active);

  const events: ServerMessage[] = [];
  manager.subscribe(session.id, (msg) => {
    events.push(msg);
  });

  return {
    manager,
    events,
    session,
    sdkBackend,
    prompt,
  };
}

function asTurnAcks(events: ServerMessage[]): Array<Extract<ServerMessage, { type: "turn_ack" }>> {
  return messagesOfType(events, "turn_ack");
}

function asRpcResults(
  events: ServerMessage[],
): Array<Extract<ServerMessage, { type: "command_result" }>> {
  return messagesOfType(events, "command_result");
}

function asStateEvents(events: ServerMessage[]): Array<Extract<ServerMessage, { type: "state" }>> {
  return messagesOfType(events, "state");
}

describe("turn delivery idempotency", () => {
  it("dedupes duplicate prompt retries by clientTurnId", async () => {
    const { manager, events, prompt, session } = makeManagerHarness("ready");

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

    expect(prompt).toHaveBeenCalledTimes(1);
    expect(session.messageCount).toBe(1);
    expect(session.lastMessage).toBe("hello");

    const turnAcks = asTurnAcks(events);
    expect(turnAcks).toHaveLength(3);

    const duplicateAck = turnAcks.find((ack) => ack.requestId === "req-2");
    expect(duplicateAck?.stage).toBe("dispatched");
    expect(duplicateAck?.duplicate).toBe(true);
  });

  it("rejects conflicting payload reuse for the same clientTurnId", async () => {
    const { manager, events, prompt } = makeManagerHarness("ready");

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

    expect(prompt).toHaveBeenCalledTimes(1);

    const turnAcks = asTurnAcks(events);
    expect(turnAcks).toHaveLength(2);
  });

  it("absorbs duplicate retry storms without duplicate persistence", async () => {
    const { manager, events, prompt } = makeManagerHarness("ready");
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

    expect(prompt).toHaveBeenCalledTimes(1);

    (
      manager as unknown as { handlePiEvent: (sessionKey: string, data: unknown) => void }
    ).handlePiEvent(key, { type: "agent_start" });

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

    expect(prompt).toHaveBeenCalledTimes(1);

    const duplicateAcks = asTurnAcks(events).filter((ack) => ack.duplicate);
    expect(duplicateAcks).toHaveLength(
      dispatchedDuplicateReqIds.length + startedDuplicateReqIds.length,
    );

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
    const { manager, events, prompt } = makeManagerHarness("ready");
    const key = "s1";

    await manager.sendPrompt("s1", "hello", {
      clientTurnId: "turn-1",
      requestId: "req-1",
      timestamp: 1,
    });

    (
      manager as unknown as { handlePiEvent: (sessionKey: string, data: unknown) => void }
    ).handlePiEvent(key, { type: "agent_start" });

    await manager.sendPrompt("s1", "hello", {
      clientTurnId: "turn-1",
      requestId: "req-2",
      timestamp: 2,
    });

    expect(prompt).toHaveBeenCalledTimes(1);

    const turnAcks = asTurnAcks(events);
    const duplicateAck = turnAcks.find((ack) => ack.requestId === "req-2");
    expect(duplicateAck?.stage).toBe("started");
    expect(duplicateAck?.duplicate).toBe(true);
  });

  it("rejects busy prompt without mutating local turn state", async () => {
    const { manager, events, prompt, session } = makeManagerHarness("busy");

    await expect(
      manager.sendPrompt("s1", "should not append", {
        clientTurnId: "turn-busy-prompt",
        requestId: "req-busy-prompt",
        timestamp: 1,
      }),
    ).rejects.toThrow("Prompt requires an idle session");

    expect(prompt).not.toHaveBeenCalled();
    expect(session.messageCount).toBe(0);
    expect(session.lastMessage).toBeUndefined();
    expect(asTurnAcks(events)).toHaveLength(0);
  });

  it("treats SDK streaming as busy when stored session status is stale ready", async () => {
    const { manager, events, prompt, session, sdkBackend } = makeManagerHarness("ready");
    (sdkBackend as { isStreaming: boolean }).isStreaming = true;

    await expect(
      manager.sendPrompt("s1", "continue", {
        clientTurnId: "turn-stale-ready",
        requestId: "req-stale-ready",
        timestamp: 1,
      }),
    ).rejects.toThrow("Prompt requires an idle session");

    expect(prompt).not.toHaveBeenCalled();
    expect(session.messageCount).toBe(0);
    expect(session.lastMessage).toBeUndefined();
    expect(asTurnAcks(events)).toHaveLength(0);
  });

  it("allows follow-up delivery when SDK is streaming but stored status is stale ready", async () => {
    const { manager, prompt, sdkBackend } = makeManagerHarness("ready");
    (sdkBackend as { isStreaming: boolean }).isStreaming = true;

    await manager.sendFollowUp("s1", "continue", {
      clientTurnId: "turn-follow-up-stale-ready",
      requestId: "req-follow-up-stale-ready",
    });

    expect(prompt).toHaveBeenCalledWith(
      "continue",
      expect.objectContaining({
        images: undefined,
        streamingBehavior: "followUp",
      }),
    );
  });

  it("queues compact while busy and runs it after agent_settled", async () => {
    const { manager, events, sdkBackend, session } = makeManagerHarness("busy");

    await manager.forwardClientCommand(
      "s1",
      { type: "compact", customInstructions: "keep the test evidence" },
      "req-compact-busy",
    );

    expect(sdkBackend.session.compact).not.toHaveBeenCalled();
    expect(asRpcResults(events)).toHaveLength(0);

    (
      manager as unknown as { handlePiEvent: (sessionKey: string, data: unknown) => void }
    ).handlePiEvent("s1", { type: "agent_settled" });

    expect(session.status).toBe("ready");
    expect(sdkBackend.session.compact).toHaveBeenCalledOnce();
    expect(sdkBackend.session.compact).toHaveBeenCalledWith("keep the test evidence");
    await vi.waitFor(() => {
      const compactResult = asRpcResults(events).find(
        (event) => event.requestId === "req-compact-busy",
      );
      expect(compactResult?.success).toBe(true);
    });
  });

  it("queues compact when SDK streaming state is newer than stored status", async () => {
    const { manager, events, sdkBackend } = makeManagerHarness("ready");
    (sdkBackend as { isStreaming: boolean }).isStreaming = true;

    await manager.forwardClientCommand("s1", { type: "compact" }, "req-compact-stale-ready");

    expect(sdkBackend.session.compact).not.toHaveBeenCalled();

    (sdkBackend as { isStreaming: boolean }).isStreaming = false;
    (
      manager as unknown as { handlePiEvent: (sessionKey: string, data: unknown) => void }
    ).handlePiEvent("s1", { type: "agent_settled" });

    expect(sdkBackend.session.compact).toHaveBeenCalledOnce();
    await vi.waitFor(() => {
      expect(
        asRpcResults(events).find((event) => event.requestId === "req-compact-stale-ready")
          ?.success,
      ).toBe(true);
    });
  });

  it("queues compact while automatic compaction is part of the active turn", async () => {
    const { manager, events, sdkBackend } = makeManagerHarness("busy");
    (sdkBackend as { isStreaming: boolean }).isStreaming = true;
    (sdkBackend as { isCompacting: boolean }).isCompacting = true;

    await manager.forwardClientCommand("s1", { type: "compact" }, "req-compact-auto");
    expect(sdkBackend.session.compact).not.toHaveBeenCalled();

    (sdkBackend as { isStreaming: boolean }).isStreaming = false;
    (sdkBackend as { isCompacting: boolean }).isCompacting = false;
    (
      manager as unknown as { handlePiEvent: (sessionKey: string, data: unknown) => void }
    ).handlePiEvent("s1", { type: "agent_settled" });

    expect(sdkBackend.session.compact).toHaveBeenCalledOnce();
    await vi.waitFor(() => {
      expect(
        asRpcResults(events).find((event) => event.requestId === "req-compact-auto")?.success,
      ).toBe(true);
    });
  });

  it("fails a queued compact if the session ends before settling", async () => {
    const { manager, events, sdkBackend } = makeManagerHarness("busy");

    await manager.forwardClientCommand("s1", { type: "compact" }, "req-compact-ended");

    await (
      manager as unknown as {
        handleSessionEnd: (key: string, reason: string) => Promise<void>;
      }
    ).handleSessionEnd("s1", "test session ended");

    expect(sdkBackend.session.compact).not.toHaveBeenCalled();
    const result = asRpcResults(events).find((event) => event.requestId === "req-compact-ended");
    expect(result?.success).toBe(false);
    expect(result?.error).toContain("Session ended before queued compact could run");
    expect(manager.isActive("s1")).toBe(false);
  });

  it("rejects idle-only commands while manual compaction is already running", async () => {
    const { manager, events, sdkBackend } = makeManagerHarness("ready");
    (sdkBackend as { isCompacting: boolean }).isCompacting = true;

    await manager.forwardClientCommand("s1", { type: "compact" }, "req-compact-duplicate");
    await manager.forwardClientCommand(
      "s1",
      { type: "navigate_tree", targetId: "entry-1" },
      "req-tree-compacting",
    );

    expect(sdkBackend.session.compact).not.toHaveBeenCalled();
    for (const requestId of ["req-compact-duplicate", "req-tree-compacting"]) {
      const result = asRpcResults(events).find((event) => event.requestId === requestId);
      expect(result?.success).toBe(false);
      expect(result?.error).toContain("requires an idle session");
    }
  });

  it("resumes queued compact even if settled-state persistence fails", async () => {
    const { manager, sdkBackend } = makeManagerHarness("busy");

    await manager.forwardClientCommand("s1", { type: "compact" }, "req-compact-persist-fail");
    vi.spyOn(
      manager as unknown as { persistSessionNow: (key: string, session: Session) => void },
      "persistSessionNow",
    ).mockImplementation(() => {
      throw new Error("settled persistence failed");
    });

    (
      manager as unknown as { handlePiEvent: (sessionKey: string, data: unknown) => void }
    ).handlePiEvent("s1", { type: "agent_settled" });

    expect(sdkBackend.session.compact).toHaveBeenCalledOnce();
  });

  it("still rejects navigate_tree while the session is busy", async () => {
    const { manager, events } = makeManagerHarness("busy");

    await manager.forwardClientCommand(
      "s1",
      { type: "navigate_tree", targetId: "entry-1" },
      "req-tree-busy",
    );

    const treeResult = asRpcResults(events).find((event) => event.requestId === "req-tree-busy");
    expect(treeResult?.success).toBe(false);
    expect(treeResult?.error).toContain("navigate_tree requires an idle session");
  });

  it("rejects in-wrapper fork instead of replacing focused-session identity", async () => {
    const { manager, events, session } = makeManagerHarness("ready");

    await manager.forwardClientCommand("s1", { type: "fork", entryId: "msg-123" }, "req-fork-1");

    expect(session).not.toHaveProperty("piSessionId");
    const rpcResult = asRpcResults(events).find((event) => event.command === "fork");
    expect(rpcResult?.success).toBe(false);
    expect(rpcResult?.error).toMatch(/not allowed|Oppi lifecycle|distinct canonical/i);
  });

  it("mirrors thinking level after set_thinking_level without Oppi-owned per-model persistence", async () => {
    const { manager, session, events } = makeManagerHarness("ready");

    session.model = "anthropic/claude-sonnet-4-0";

    const sendCommandAsync = vi.fn(async (_key: string, command: Record<string, unknown>) => {
      if (command.type === "set_thinking_level") {
        return {};
      }

      throw new Error(`unexpected command: ${String(command.type)}`);
    });

    (manager as unknown as { sendCommandAsync: typeof sendCommandAsync }).sendCommandAsync =
      sendCommandAsync;

    await manager.forwardClientCommand(
      "s1",
      { type: "set_thinking_level", level: "high" },
      "req-thinking-1",
    );

    expect(session.thinkingLevel).toBe("high");

    const stateEvent = asStateEvents(events).at(-1);
    expect(stateEvent?.session.thinkingLevel).toBe("high");
  });

  it("uses Pi-returned thinking after set_model without Oppi-owned per-model memory", async () => {
    const { manager, session, events } = makeManagerHarness("ready");

    const sendCommandAsync = vi.fn(async (_key: string, command: Record<string, unknown>) => {
      if (command.type === "set_model") {
        return { provider: "anthropic", id: "claude-sonnet-4-0", thinkingLevel: "minimal" };
      }

      if (command.type === "get_state") {
        return {
          model: { provider: "anthropic", id: "claude-sonnet-4-0" },
          thinkingLevel: "minimal",
        };
      }

      throw new Error(`unexpected command: ${String(command.type)}`);
    });

    (manager as unknown as { sendCommandAsync: typeof sendCommandAsync }).sendCommandAsync =
      sendCommandAsync;

    await manager.forwardClientCommand(
      "s1",
      { type: "set_model", provider: "anthropic", modelId: "claude-sonnet-4-0" },
      "req-model-1",
    );

    expect(sendCommandAsync).toHaveBeenNthCalledWith(
      1,
      "s1",
      expect.objectContaining({
        type: "set_model",
        provider: "anthropic",
        modelId: "claude-sonnet-4-0",
      }),
    );

    expect(sendCommandAsync).toHaveBeenCalledTimes(1);

    expect(session.model).toBe("anthropic/claude-sonnet-4-0");
    expect(session.thinkingLevel).toBe("minimal");

    const stateEvent = asStateEvents(events).at(-1);
    expect(stateEvent?.session.model).toBe("anthropic/claude-sonnet-4-0");
    expect(stateEvent?.session.thinkingLevel).toBe("minimal");
  });

  it("prefixes provider on nested model IDs from get_state (e.g. openrouter/z.ai/glm-5)", async () => {
    const { manager, session, events } = makeManagerHarness("ready");

    // Simulate pi reporting a nested-provider model via get_state.
    // The model id contains a slash (z.ai/glm-5) but the provider is "openrouter".
    const sendCommandAsync = vi.fn(async (_key: string, command: Record<string, unknown>) => {
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

    (manager as unknown as { sendCommandAsync: typeof sendCommandAsync }).sendCommandAsync =
      sendCommandAsync;

    await manager.forwardClientCommand(
      "s1",
      { type: "set_model", provider: "openrouter", modelId: "z.ai/glm-5" },
      "req-nested-1",
    );

    // The session model must include the provider prefix, not just "z.ai/glm-5"
    expect(session.model).toBe("openrouter/z.ai/glm-5");

    const stateEvent = asStateEvents(events).at(-1);
    expect(stateEvent?.session.model).toBe("openrouter/z.ai/glm-5");
  });

  it("does not double-prefix when model id already starts with provider", async () => {
    const { manager, session } = makeManagerHarness("ready");

    const sendCommandAsync = vi.fn(async (_key: string, command: Record<string, unknown>) => {
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

    (manager as unknown as { sendCommandAsync: typeof sendCommandAsync }).sendCommandAsync =
      sendCommandAsync;

    await manager.forwardClientCommand(
      "s1",
      { type: "set_model", provider: "anthropic", modelId: "claude-sonnet-4-0" },
      "req-simple-1",
    );

    // Must be "anthropic/claude-sonnet-4-0", not "anthropic/anthropic/claude-sonnet-4-0"
    expect(session.model).toBe("anthropic/claude-sonnet-4-0");
  });
});
