/**
 * Session lifecycle tests — state queries, RPC line handling, broadcast,
 * cleanup, prompt/steer/follow_up commands, extension UI protocol, and
 * turn dedupe. Complements stop-lifecycle.test.ts (stop/abort flows).
 */
import type { ChildProcess } from "node:child_process";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { EventRing } from "../src/event-ring.js";
import { SessionManager, type ExtensionUIResponse } from "../src/sessions.js";
import { TurnDedupeCache } from "../src/turn-cache.js";
import type { GateServer } from "../src/gate.js";
import type { SandboxManager } from "../src/sandbox.js";
import type { Storage } from "../src/storage.js";
import type { ServerConfig, ServerMessage, Session } from "../src/types.js";

const TEST_CONFIG: ServerConfig = {
  port: 7749,
  host: "127.0.0.1",
  dataDir: "/tmp/oppi-lifecycle-tests",
  defaultModel: "anthropic/claude-sonnet-4-0",
  sessionTimeout: 600_000,
  sessionIdleTimeoutMs: 600_000,
  workspaceIdleTimeoutMs: 1_800_000,
  maxSessionsPerWorkspace: 3,
  maxSessionsGlobal: 5,
};

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
    runtime: "host",
    ...overrides,
  };
}

function makeProcessStub(): {
  process: ChildProcess;
  stdinWrite: ReturnType<typeof vi.fn>;
  kill: ReturnType<typeof vi.fn>;
} {
  const stdinWrite = vi.fn();
  const proc = {
    stdin: { write: stdinWrite, writable: true },
    killed: false,
  } as unknown as ChildProcess;

  const kill = vi.fn(() => {
    (proc as { killed: boolean }).killed = true;
    return true;
  });
  (proc as { kill: typeof kill }).kill = kill;

  return { process: proc, stdinWrite, kill };
}

function makeManagerHarness(sessionOverrides: Partial<Session> = {}) {
  const storage = {
    getConfig: () => TEST_CONFIG,
    saveSession: vi.fn(),
    addSessionMessage: vi.fn(),
    getWorkspace: vi.fn(() => null),
  } as unknown as Storage;

  const gate = {
    destroySessionSocket: vi.fn(),
    getGuardState: vi.fn(() => "guarded"),
  } as unknown as GateServer;

  const sandbox = {
    stopAll: vi.fn(async () => {}),
    stopWorkspaceContainer: vi.fn(async () => {}),
  } as unknown as SandboxManager;

  const manager = new SessionManager(storage, gate, sandbox);

  // Disable idle timers for deterministic tests.
  (manager as unknown as { resetIdleTimer: (key: string) => void }).resetIdleTimer = () => {};

  const { process, stdinWrite, kill } = makeProcessStub();
  const session = makeSession(sessionOverrides);

  // Inject active session directly into the manager.
  const active = {
    session,
    process,
    workspaceId: session.workspaceId ?? "w1",
    runtime: session.runtime ?? "host",
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
    session,
    events,
    active,
    stdinWrite,
    kill,
    storage,
    gate,
  };
}

// Helper to call handleRpcLine which is private
function feedRpcLine(manager: SessionManager, key: string, data: unknown): void {
  (manager as unknown as { handleRpcLine: (key: string, line: string) => void }).handleRpcLine(
    key,
    JSON.stringify(data),
  );
}

// ─── State Queries ───

describe("SessionManager state queries", () => {
  it("isActive returns true for active session", () => {
    const { manager } = makeManagerHarness();
    expect(manager.isActive("s1")).toBe(true);
  });

  it("isActive returns false for nonexistent session", () => {
    const { manager } = makeManagerHarness();
    expect(manager.isActive("no-such-session")).toBe(false);
  });

  it("getActiveSession returns session object", () => {
    const { manager } = makeManagerHarness();
    const session = manager.getActiveSession("s1");
    expect(session).toBeDefined();
    expect(session!.id).toBe("s1");
  });

  it("getActiveSession returns undefined for inactive", () => {
    const { manager } = makeManagerHarness();
    expect(manager.getActiveSession("nope")).toBeUndefined();
  });

  it("getCurrentSeq returns 0 for fresh session", () => {
    const { manager } = makeManagerHarness();
    expect(manager.getCurrentSeq("s1")).toBe(0);
  });

  it("getCurrentSeq returns 0 for nonexistent session", () => {
    const { manager } = makeManagerHarness();
    expect(manager.getCurrentSeq("nope")).toBe(0);
  });

  it("hasPendingUIRequest returns false when no requests", () => {
    const { manager } = makeManagerHarness();
    expect(manager.hasPendingUIRequest("s1", "req-1")).toBe(false);
  });
});

// ─── Catch-up ───

describe("SessionManager catch-up", () => {
  it("getCatchUp returns null for nonexistent session", () => {
    const { manager } = makeManagerHarness();
    expect(manager.getCatchUp("nope", 0)).toBeNull();
  });

  it("getCatchUp returns empty events from seq 0", () => {
    const { manager } = makeManagerHarness();
    const result = manager.getCatchUp("s1", 0);
    expect(result).not.toBeNull();
    expect(result!.events).toHaveLength(0);
    expect(result!.currentSeq).toBe(0);
    expect(result!.catchUpComplete).toBe(true);
    expect(result!.session.id).toBe("s1");
  });

  it("getCatchUp returns durable events after broadcast", () => {
    const { manager } = makeManagerHarness({ status: "busy" });

    // Feed an agent_end event — which is durable
    feedRpcLine(manager, "s1", { type: "agent_end" });

    const result = manager.getCatchUp("s1", 0);
    expect(result!.currentSeq).toBeGreaterThan(0);
    expect(result!.events.length).toBeGreaterThan(0);
  });
});

// ─── Subscribe / Broadcast ───

describe("SessionManager subscribe", () => {
  it("subscriber receives broadcast events", () => {
    const { manager, events } = makeManagerHarness({ status: "busy" });

    feedRpcLine(manager, "s1", { type: "agent_end" });

    // Should receive state and agent_end messages
    expect(events.length).toBeGreaterThan(0);
  });

  it("unsubscribe stops delivery", () => {
    const { manager, session } = makeManagerHarness({ status: "busy" });

    const laterEvents: ServerMessage[] = [];
    const unsub = manager.subscribe("s1", (msg) => {
      laterEvents.push(msg);
    });

    feedRpcLine(manager, "s1", { type: "agent_end" });
    const countBeforeUnsub = laterEvents.length;

    unsub();

    // Re-set status to busy so we can trigger another event
    session.status = "busy";
    feedRpcLine(manager, "s1", { type: "agent_end" });

    expect(laterEvents.length).toBe(countBeforeUnsub);
  });

  it("subscribe to nonexistent session returns no-op unsubscribe", () => {
    const { manager } = makeManagerHarness();
    const unsub = manager.subscribe("nonexistent", () => {});
    expect(typeof unsub).toBe("function");
    unsub(); // should not throw
  });
});

// ─── RPC Response Correlation ───

describe("SessionManager RPC response correlation", () => {
  it("correlates RPC response by id to pending handler", () => {
    const { manager, active } = makeManagerHarness();

    let resolved: unknown = undefined;
    active.pendingResponses.set("rpc-42", (data: unknown) => {
      resolved = data;
    });

    feedRpcLine(manager, "s1", {
      type: "response",
      id: "rpc-42",
      success: true,
      data: { model: "claude" },
    });

    expect(resolved).toBeDefined();
    expect(active.pendingResponses.has("rpc-42")).toBe(false);
  });

  it("broadcasts error for uncorrelated failed response with no pending", () => {
    const { manager, events } = makeManagerHarness();

    feedRpcLine(manager, "s1", {
      type: "response",
      id: "rpc-999",
      success: false,
      error: "command not found",
    });

    expect(events.some((e) => e.type === "error")).toBe(true);
  });

  it("routes uncorrelated error to sole pending handler", () => {
    const { manager, active, events } = makeManagerHarness();

    let resolved: unknown = undefined;
    active.pendingResponses.set("rpc-50", (data: unknown) => {
      resolved = data;
    });

    // Uncorrelated (no id) error response with exactly one pending
    feedRpcLine(manager, "s1", {
      type: "response",
      success: false,
      error: "parse error",
    });

    expect(resolved).toBeDefined();
    expect(active.pendingResponses.size).toBe(0);
  });

  it("handles invalid JSON gracefully", () => {
    const { manager, events } = makeManagerHarness();

    // Direct call with invalid JSON
    (manager as unknown as { handleRpcLine: (key: string, line: string) => void }).handleRpcLine(
      "s1",
      "this is not json{{{",
    );

    // Should not crash, no error event broadcast (just console.warn)
    expect(events.some((e) => e.type === "session_ended")).toBe(false);
  });
});

// ─── Extension UI Protocol ───

describe("SessionManager extension UI", () => {
  it("forwards fire-and-forget notification methods", () => {
    const { manager, events } = makeManagerHarness();

    feedRpcLine(manager, "s1", {
      type: "extension_ui_request",
      id: "ui-1",
      method: "notify",
      message: "Hello from extension",
      notifyType: "info",
    });

    const notif = events.find((e) => e.type === "extension_ui_notification");
    expect(notif).toBeDefined();
  });

  it("tracks dialog methods as pending UI requests", () => {
    const { manager, events, active } = makeManagerHarness();

    feedRpcLine(manager, "s1", {
      type: "extension_ui_request",
      id: "ui-2",
      method: "select",
      title: "Pick an option",
      options: ["a", "b"],
    });

    expect(active.pendingUIRequests.has("ui-2")).toBe(true);
    const uiReq = events.find((e) => e.type === "extension_ui_request");
    expect(uiReq).toBeDefined();
  });

  it("respondToUIRequest sends response to stdin", () => {
    const { manager, active, stdinWrite } = makeManagerHarness();

    // Set up a pending request
    active.pendingUIRequests.set("ui-3", {
      type: "extension_ui_request",
      id: "ui-3",
      method: "confirm",
      title: "Are you sure?",
    });

    const response: ExtensionUIResponse = {
      type: "extension_ui_response",
      id: "ui-3",
      confirmed: true,
    };

    const result = manager.respondToUIRequest("s1", response);
    expect(result).toBe(true);
    expect(active.pendingUIRequests.has("ui-3")).toBe(false);
    expect(stdinWrite).toHaveBeenCalled();
  });

  it("respondToUIRequest returns false for unknown request", () => {
    const { manager } = makeManagerHarness();

    const result = manager.respondToUIRequest("s1", {
      type: "extension_ui_response",
      id: "nonexistent",
      confirmed: true,
    });

    expect(result).toBe(false);
  });

  it("respondToUIRequest returns false for nonexistent session", () => {
    const { manager } = makeManagerHarness();

    const result = manager.respondToUIRequest("nonexistent", {
      type: "extension_ui_response",
      id: "ui-1",
      confirmed: true,
    });

    expect(result).toBe(false);
  });

  it("hasPendingUIRequest returns true for tracked request", () => {
    const { manager, active } = makeManagerHarness();

    active.pendingUIRequests.set("ui-5", {
      type: "extension_ui_request",
      id: "ui-5",
      method: "confirm",
    });

    expect(manager.hasPendingUIRequest("s1", "ui-5")).toBe(true);
    expect(manager.hasPendingUIRequest("s1", "ui-99")).toBe(false);
  });
});

// ─── Session End Cleanup ───

describe("SessionManager session end", () => {
  it("cleans up resources on session end", () => {
    const { manager, events, gate } = makeManagerHarness();

    // Trigger handleSessionEnd
    (manager as unknown as { handleSessionEnd: (key: string, reason: string) => void })
      .handleSessionEnd("s1", "completed");

    expect(events.some((e) => e.type === "session_ended")).toBe(true);
    expect(manager.isActive("s1")).toBe(false);
    expect(gate.destroySessionSocket).toHaveBeenCalledWith("s1");
  });

  it("rejects pending RPC responses on session end", () => {
    const { manager, active } = makeManagerHarness();

    let rejectedData: unknown = undefined;
    active.pendingResponses.set("rpc-99", (data: unknown) => {
      rejectedData = data;
    });

    (manager as unknown as { handleSessionEnd: (key: string, reason: string) => void })
      .handleSessionEnd("s1", "error");

    expect(rejectedData).toBeDefined();
    expect((rejectedData as { success: boolean }).success).toBe(false);
  });

  it("cancels pending UI requests on session end", () => {
    const { manager, active, stdinWrite } = makeManagerHarness();

    active.pendingUIRequests.set("ui-10", {
      type: "extension_ui_request",
      id: "ui-10",
      method: "confirm",
    });

    (manager as unknown as { handleSessionEnd: (key: string, reason: string) => void })
      .handleSessionEnd("s1", "completed");

    // Should write cancellation to stdin
    const cancelCall = stdinWrite.mock.calls.find((call: unknown[]) => {
      const line = call[0] as string;
      return line.includes("ui-10") && line.includes("cancelled");
    });
    expect(cancelCall).toBeDefined();
  });

  it("saves session with stopped status", () => {
    const { manager, session, storage } = makeManagerHarness();

    (manager as unknown as { handleSessionEnd: (key: string, reason: string) => void })
      .handleSessionEnd("s1", "completed");

    expect(session.status).toBe("stopped");
    expect(storage.saveSession).toHaveBeenCalled();
  });
});

// ─── Event Translation ───

describe("SessionManager event translation", () => {
  it("agent_start sets session status to busy", () => {
    const { manager, session } = makeManagerHarness({ status: "ready" });

    feedRpcLine(manager, "s1", { type: "agent_start" });

    expect(session.status).toBe("busy");
  });

  it("agent_end sets session status to ready", () => {
    const { manager, session } = makeManagerHarness({ status: "busy" });

    feedRpcLine(manager, "s1", { type: "agent_end" });

    expect(session.status).toBe("ready");
  });

  it("text_delta via message_update broadcasts to subscribers", () => {
    const { manager, events } = makeManagerHarness({ status: "busy" });

    feedRpcLine(manager, "s1", {
      type: "message_update",
      assistantMessageEvent: { type: "text_delta", delta: "hello" },
    });

    expect(events.some((e) => e.type === "text_delta")).toBe(true);
  });

  it("tool_execution_start updates session change stats for write tool", () => {
    const { manager, session } = makeManagerHarness({ status: "busy" });

    feedRpcLine(manager, "s1", {
      type: "tool_execution_start",
      toolName: "write",
      args: { path: "/tmp/foo.ts", content: "hello" },
      toolCallId: "tc-1",
    });

    // changeStats populated for write tool (mutating tool call counted)
    expect(session.changeStats).toBeDefined();
    expect(session.changeStats!.mutatingToolCalls).toBeGreaterThan(0);
  });

  it("message_end broadcasts message_end with role", () => {
    const { manager, events } = makeManagerHarness({ status: "busy" });

    feedRpcLine(manager, "s1", {
      type: "message_end",
      message: {
        role: "assistant",
        content: [{ type: "text", text: "Done!" }],
      },
    });

    expect(events.some((e) => e.type === "message_end")).toBe(true);
  });

  it("updates lastActivity on events", () => {
    const { manager, session } = makeManagerHarness({ status: "busy" });
    const before = session.lastActivity;

    // Small delay to ensure timestamp differs
    feedRpcLine(manager, "s1", { type: "agent_end" });

    expect(session.lastActivity).toBeGreaterThanOrEqual(before);
  });
});

// ─── Prompt / Steer / Follow-up ───

describe("SessionManager prompt", () => {
  it("sends prompt command to pi stdin", async () => {
    const { manager, stdinWrite } = makeManagerHarness({ status: "ready" });

    await manager.sendPrompt("s1", "hello world");

    // Should have written a JSON command to stdin
    expect(stdinWrite).toHaveBeenCalled();
    const written = stdinWrite.mock.calls.map((c: unknown[]) => c[0] as string).join("");
    expect(written).toContain("prompt");
    expect(written).toContain("hello world");
  });

  it("sends images with prompt", async () => {
    const { manager, stdinWrite } = makeManagerHarness({ status: "ready" });

    await manager.sendPrompt("s1", "look at this", {
      images: [{ type: "image", data: "base64data", mimeType: "image/png" }],
    });

    const written = stdinWrite.mock.calls.map((c: unknown[]) => c[0] as string).join("");
    expect(written).toContain("base64data");
    expect(written).toContain("image/png");
  });

  it("throws for nonexistent session", async () => {
    const { manager } = makeManagerHarness();
    await expect(manager.sendPrompt("nonexistent", "hi")).rejects.toThrow("not active");
  });

  it("deduplicates prompt with same clientTurnId", async () => {
    const { manager, stdinWrite, events } = makeManagerHarness({ status: "ready" });

    await manager.sendPrompt("s1", "hello", { clientTurnId: "turn-1" });
    const firstCallCount = stdinWrite.mock.calls.length;

    await manager.sendPrompt("s1", "hello", { clientTurnId: "turn-1" });

    // Second call should NOT write another command
    expect(stdinWrite.mock.calls.length).toBe(firstCallCount);

    // Should get turn_ack events with duplicate flag
    const acks = events.filter((e) => e.type === "turn_ack");
    expect(acks.length).toBeGreaterThanOrEqual(2);
  });
});

describe("SessionManager steer", () => {
  it("sends steer command when busy", async () => {
    const { manager, stdinWrite } = makeManagerHarness({ status: "busy" });

    await manager.sendSteer("s1", "focus on X");

    const written = stdinWrite.mock.calls.map((c: unknown[]) => c[0] as string).join("");
    expect(written).toContain("steer");
    expect(written).toContain("focus on X");
  });

  it("throws if session is not busy", async () => {
    const { manager } = makeManagerHarness({ status: "ready" });

    await expect(manager.sendSteer("s1", "focus")).rejects.toThrow(
      "active streaming turn",
    );
  });

  it("throws for nonexistent session", async () => {
    const { manager } = makeManagerHarness();
    await expect(manager.sendSteer("nonexistent", "hi")).rejects.toThrow("not active");
  });
});

describe("SessionManager follow_up", () => {
  it("sends follow_up command when busy", async () => {
    const { manager, stdinWrite } = makeManagerHarness({ status: "busy" });

    await manager.sendFollowUp("s1", "also do Y");

    const written = stdinWrite.mock.calls.map((c: unknown[]) => c[0] as string).join("");
    expect(written).toContain("follow_up");
    expect(written).toContain("also do Y");
  });

  it("throws if session is not busy", async () => {
    const { manager } = makeManagerHarness({ status: "ready" });

    await expect(manager.sendFollowUp("s1", "more")).rejects.toThrow(
      "active streaming turn",
    );
  });
});

// ─── RPC Passthrough ───

describe("SessionManager RPC passthrough", () => {
  it("rejects non-allowlisted commands", async () => {
    const { manager } = makeManagerHarness();

    await expect(
      manager.forwardRpcCommand("s1", { type: "evil_command" }),
    ).rejects.toThrow("not allowed");
  });

  it("throws for nonexistent session", async () => {
    const { manager } = makeManagerHarness();

    await expect(
      manager.forwardRpcCommand("nonexistent", { type: "get_state" }),
    ).rejects.toThrow("not active");
  });
});

// ─── applyPiStateSnapshot ───

describe("SessionManager applyPiStateSnapshot", () => {
  function callApplySnapshot(manager: SessionManager, session: Session, state: unknown): boolean {
    return (
      manager as unknown as {
        applyPiStateSnapshot: (session: Session, state: unknown) => boolean;
      }
    ).applyPiStateSnapshot(session, state);
  }

  it("applies sessionFile", () => {
    const { manager, session } = makeManagerHarness();

    const changed = callApplySnapshot(manager, session, {
      sessionFile: "/tmp/pi-session.jsonl",
    });

    expect(changed).toBe(true);
    expect(session.piSessionFile).toBe("/tmp/pi-session.jsonl");
  });

  it("tracks multiple session files", () => {
    const { manager, session } = makeManagerHarness();

    callApplySnapshot(manager, session, { sessionFile: "/tmp/a.jsonl" });
    callApplySnapshot(manager, session, { sessionFile: "/tmp/b.jsonl" });

    expect(session.piSessionFiles).toContain("/tmp/a.jsonl");
    expect(session.piSessionFiles).toContain("/tmp/b.jsonl");
  });

  it("applies sessionId", () => {
    const { manager, session } = makeManagerHarness();

    const changed = callApplySnapshot(manager, session, { sessionId: "uuid-123" });

    expect(changed).toBe(true);
    expect(session.piSessionId).toBe("uuid-123");
  });

  it("applies model with provider prefix", () => {
    const { manager, session } = makeManagerHarness();

    const changed = callApplySnapshot(manager, session, {
      model: { provider: "anthropic", id: "claude-sonnet-4-0" },
    });

    expect(changed).toBe(true);
    expect(session.model).toBe("anthropic/claude-sonnet-4-0");
  });

  it("applies session name", () => {
    const { manager, session } = makeManagerHarness();

    const changed = callApplySnapshot(manager, session, { sessionName: "My Session" });

    expect(changed).toBe(true);
    expect(session.name).toBe("My Session");
  });

  it("applies thinking level", () => {
    const { manager, session } = makeManagerHarness();

    const changed = callApplySnapshot(manager, session, { thinkingLevel: "high" });

    expect(changed).toBe(true);
    expect(session.thinkingLevel).toBe("high");
  });

  it("does not persist thinking preference on state snapshot", () => {
    // Regression: applyPiStateSnapshot used to call persistThinkingPreference,
    // which clobbered the user's saved preference with pi's factory default
    // during bootstrap. This made applyRememberedThinkingLevel a permanent no-op.
    const setModelPref = vi.fn();
    const { manager, session } = makeManagerHarness();
    // Patch in the storage method that persists thinking preferences
    (
      (manager as unknown as { storage: Record<string, unknown> }).storage as Record<
        string,
        unknown
      >
    ).setModelThinkingLevelPreference = setModelPref;

    session.model = "anthropic/claude-sonnet-4-0";
    callApplySnapshot(manager, session, { thinkingLevel: "high" });

    expect(setModelPref).not.toHaveBeenCalled();
  });

  it("returns false for null/undefined state", () => {
    const { manager, session } = makeManagerHarness();

    expect(callApplySnapshot(manager, session, null)).toBe(false);
    expect(callApplySnapshot(manager, session, undefined)).toBe(false);
  });

  it("returns false when nothing changed", () => {
    const { manager, session } = makeManagerHarness();
    session.piSessionFile = "/tmp/same.jsonl";
    session.piSessionFiles = ["/tmp/same.jsonl"];
    session.piSessionId = "uuid-1";

    const changed = callApplySnapshot(manager, session, {
      sessionFile: "/tmp/same.jsonl",
      sessionId: "uuid-1",
    });

    expect(changed).toBe(false);
  });

  it("ignores empty string values", () => {
    const { manager, session } = makeManagerHarness();

    const changed = callApplySnapshot(manager, session, {
      sessionFile: "",
      sessionId: "",
      sessionName: "",
    });

    expect(changed).toBe(false);
  });
});

// ─── RPC Response Dispatch ───

describe("handleRpcLine response dispatch", () => {
  it("dispatches correlated RPC success to pending handler", () => {
    const { manager, active } = makeManagerHarness();
    const result = vi.fn();
    active.pendingResponses.set("req-42", result);

    feedRpcLine(manager, "s1", {
      type: "response",
      id: "req-42",
      success: true,
      command: "get_state",
      data: { model: "test" },
    });

    expect(result).toHaveBeenCalledWith(
      expect.objectContaining({ success: true, command: "get_state" }),
    );
    expect(active.pendingResponses.size).toBe(0);
  });

  it("dispatches correlated RPC failure to pending handler", () => {
    const { manager, active } = makeManagerHarness();
    const result = vi.fn();
    active.pendingResponses.set("req-99", result);

    feedRpcLine(manager, "s1", {
      type: "response",
      id: "req-99",
      success: false,
      command: "set_thinking_level",
      error: "unsupported",
    });

    expect(result).toHaveBeenCalledWith(
      expect.objectContaining({ success: false }),
    );
    expect(active.pendingResponses.size).toBe(0);
  });

  it("broadcasts error for orphaned failed response with id", () => {
    const { manager, events } = makeManagerHarness();

    feedRpcLine(manager, "s1", {
      type: "response",
      id: "orphan-id",
      success: false,
      command: "unknown_cmd",
      error: "bad request",
    });

    expect(events.some((e) => e.type === "error")).toBe(true);
  });

  it("attributes uncorrelated failure to single pending handler", () => {
    const { manager, active } = makeManagerHarness();
    const result = vi.fn();
    active.pendingResponses.set("only-one", result);

    feedRpcLine(manager, "s1", {
      type: "response",
      success: false,
      command: "set_model",
      error: "model not found",
    });

    expect(result).toHaveBeenCalledWith(
      expect.objectContaining({ success: false }),
    );
    expect(active.pendingResponses.size).toBe(0);
  });

  it("broadcasts error for uncorrelated failure with multiple pending", () => {
    const { manager, active, events } = makeManagerHarness();
    active.pendingResponses.set("a", vi.fn());
    active.pendingResponses.set("b", vi.fn());

    feedRpcLine(manager, "s1", {
      type: "response",
      success: false,
      command: "rpc",
      error: "ambiguous",
    });

    // Neither handler should be called — broadcast error instead
    expect(events.some((e) => e.type === "error")).toBe(true);
    expect(active.pendingResponses.size).toBe(2);
  });

  it("ignores invalid JSON lines", () => {
    const { manager, events } = makeManagerHarness();
    // Feed raw invalid JSON
    (manager as unknown as { handleRpcLine: (key: string, line: string) => void }).handleRpcLine(
      "s1",
      "not valid json {{{",
    );
    expect(events.length).toBe(0);
  });

  it("ignores lines for unknown session", () => {
    const { manager, events } = makeManagerHarness();
    feedRpcLine(manager, "nonexistent", {
      type: "response",
      success: true,
      command: "get_state",
    });
    expect(events.length).toBe(0);
  });
});

// ─── Event Translation & Broadcast ───

describe("handleRpcLine event translation", () => {
  it("broadcasts tool_execution_start event", () => {
    const { manager, events } = makeManagerHarness();

    feedRpcLine(manager, "s1", {
      type: "tool_execution_start",
      toolName: "bash",
      toolCallId: "tc-1",
    });

    expect(events.some((e) => e.type === "tool_start")).toBe(true);
  });

  it("broadcasts tool_execution_end event", () => {
    const { manager, events } = makeManagerHarness();

    feedRpcLine(manager, "s1", {
      type: "tool_execution_end",
      toolName: "bash",
      toolCallId: "tc-1",
    });

    expect(events.some((e) => e.type === "tool_end")).toBe(true);
  });

  it("broadcasts message_end with assistant content", () => {
    const { manager, events } = makeManagerHarness();

    feedRpcLine(manager, "s1", {
      type: "message_end",
      message: {
        role: "assistant",
        content: [{ type: "text", text: "Hello world" }],
      },
    });

    const msgEnd = events.find((e) => e.type === "message_end");
    expect(msgEnd).toBeDefined();
  });

  it("updates session status to busy on agent_start", () => {
    const { manager, session } = makeManagerHarness();

    feedRpcLine(manager, "s1", { type: "agent_start" });

    expect(session.status).toBe("busy");
  });

  it("updates session status to ready on agent_end", () => {
    const { manager, session } = makeManagerHarness();
    session.status = "busy";

    feedRpcLine(manager, "s1", { type: "agent_end" });

    expect(session.status).toBe("ready");
  });

  it("broadcasts state after status-changing events", () => {
    const { manager, events } = makeManagerHarness();

    feedRpcLine(manager, "s1", { type: "agent_start" });

    const stateEvents = events.filter((e) => e.type === "state");
    expect(stateEvents.length).toBeGreaterThanOrEqual(1);
  });

  it("broadcasts text_delta for message_update with text_delta", () => {
    const { manager, events } = makeManagerHarness();

    feedRpcLine(manager, "s1", {
      type: "message_update",
      assistantMessageEvent: { type: "text_delta", delta: "hello " },
    });

    expect(events.some((e) => e.type === "text_delta")).toBe(true);
  });

  it("broadcasts thinking_delta for message_update with thinking_delta", () => {
    const { manager, events } = makeManagerHarness();

    feedRpcLine(manager, "s1", {
      type: "message_update",
      assistantMessageEvent: { type: "thinking_delta", delta: "let me think..." },
    });

    expect(events.some((e) => e.type === "thinking_delta")).toBe(true);
  });
});

// ─── Extension UI Protocol ───

describe("extension UI protocol", () => {
  it("forwards dialog UI request to subscribers", () => {
    const { manager, events } = makeManagerHarness();

    feedRpcLine(manager, "s1", {
      type: "extension_ui_request",
      id: "ui-dialog-1",
      method: "select",
      title: "Pick one",
      options: [{ label: "A" }, { label: "B" }],
    });

    const uiReq = events.find((e) => e.type === "extension_ui_request");
    expect(uiReq).toBeDefined();
    expect(manager.hasPendingUIRequest("s1", "ui-dialog-1")).toBe(true);
  });

  it("forwards fire-and-forget UI methods as notifications", () => {
    const { manager, events } = makeManagerHarness();

    feedRpcLine(manager, "s1", {
      type: "extension_ui_request",
      id: "ui-notify-1",
      method: "notify",
      message: "Done!",
    });

    const notif = events.find((e) => e.type === "extension_ui_notification");
    expect(notif).toBeDefined();
    // Fire-and-forget should NOT be pending
    expect(manager.hasPendingUIRequest("s1", "ui-notify-1")).toBe(false);
  });

  it("respondToUIRequest writes to stdin and clears pending", () => {
    const { manager, stdinWrite } = makeManagerHarness();

    // Set up a pending dialog
    feedRpcLine(manager, "s1", {
      type: "extension_ui_request",
      id: "ui-resp-1",
      method: "confirm",
      title: "Are you sure?",
    });

    const ok = manager.respondToUIRequest("s1", {
      id: "ui-resp-1",
      result: true,
    });

    expect(ok).toBe(true);
    expect(stdinWrite).toHaveBeenCalled();
    expect(manager.hasPendingUIRequest("s1", "ui-resp-1")).toBe(false);
  });

  it("respondToUIRequest returns false for unknown request", () => {
    const { manager } = makeManagerHarness();

    const ok = manager.respondToUIRequest("s1", {
      id: "nonexistent",
      result: null,
    });

    expect(ok).toBe(false);
  });
});

// ─── Session Catch-Up ───

describe("session catch-up", () => {
  it("getCatchUp returns events after given seq", () => {
    const { manager, active } = makeManagerHarness();

    // Simulate some events by feeding agent_start/end
    feedRpcLine(manager, "s1", { type: "agent_start" });
    feedRpcLine(manager, "s1", { type: "text_delta", text: "hi" });
    feedRpcLine(manager, "s1", { type: "agent_end" });

    const catchUp = manager.getCatchUp("s1", 0);
    expect(catchUp).not.toBeNull();
    expect(catchUp!.events.length).toBeGreaterThan(0);
  });

  it("getCatchUp returns null for nonexistent session", () => {
    const { manager } = makeManagerHarness();
    expect(manager.getCatchUp("nope", 0)).toBeNull();
  });
});

// ─── updateSessionFromEvent ───

describe("updateSessionFromEvent", () => {
  it("increments messageCount on message_end with assistant text", () => {
    const { manager, session } = makeManagerHarness();
    const initialCount = session.messageCount;

    feedRpcLine(manager, "s1", {
      type: "message_end",
      message: {
        role: "assistant",
        content: [{ type: "text", text: "Hello world" }],
        usage: { input: 10, output: 5 },
      },
    });

    expect(session.messageCount).toBe(initialCount + 1);
  });

  it("updates tokens from message_end with assistant text", () => {
    const { manager, session } = makeManagerHarness();

    feedRpcLine(manager, "s1", {
      type: "message_end",
      message: {
        role: "assistant",
        content: [{ type: "text", text: "Hello" }],
        usage: { input: 100, output: 50, cacheRead: 0, cacheWrite: 0 },
      },
    });

    expect(session.tokens.input).toBe(100);
    expect(session.tokens.output).toBe(50);
  });

  it("accumulates tokens across multiple message_end events", () => {
    const { manager, session } = makeManagerHarness();

    feedRpcLine(manager, "s1", {
      type: "message_end",
      message: {
        role: "assistant",
        content: [{ type: "text", text: "first" }],
        usage: { input: 100, output: 50, cacheRead: 0, cacheWrite: 0 },
      },
    });

    feedRpcLine(manager, "s1", {
      type: "message_end",
      message: {
        role: "assistant",
        content: [{ type: "text", text: "second" }],
        usage: { input: 200, output: 100, cacheRead: 0, cacheWrite: 0 },
      },
    });

    expect(session.tokens.input).toBe(300);
    expect(session.tokens.output).toBe(150);
  });

  it("updates lastActivity on events", () => {
    const { manager, session } = makeManagerHarness();
    const before = session.lastActivity;

    feedRpcLine(manager, "s1", { type: "agent_start" });

    expect(session.lastActivity).toBeGreaterThanOrEqual(before);
  });

  it("updates context tokens from message_end usage", () => {
    const { manager, session } = makeManagerHarness();

    feedRpcLine(manager, "s1", {
      type: "message_end",
      message: {
        role: "assistant",
        content: [{ type: "text", text: "hi" }],
        usage: { input: 1000, output: 200, cacheRead: 500, cacheWrite: 100 },
      },
    });

    // contextTokens = input + output + cacheRead + cacheWrite
    expect(session.contextTokens).toBe(1800);
  });

  it("does not increment messageCount for user message_end", () => {
    const { manager, session } = makeManagerHarness();
    const initialCount = session.messageCount;

    feedRpcLine(manager, "s1", {
      type: "message_end",
      message: { role: "user", content: [{ type: "text", text: "hi" }] },
    });

    expect(session.messageCount).toBe(initialCount);
  });

  it("updates cost from message_end usage", () => {
    const { manager, session } = makeManagerHarness();

    feedRpcLine(manager, "s1", {
      type: "message_end",
      message: {
        role: "assistant",
        content: [{ type: "text", text: "response" }],
        usage: { input: 100, output: 50, cost: { total: 0.003 } },
      },
    });

    expect(session.cost).toBeCloseTo(0.003);
  });
});
