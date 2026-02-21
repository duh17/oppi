/**
 * Session lifecycle tests — state queries, RPC line handling, broadcast,
 * cleanup, prompt/steer/follow_up commands, extension UI protocol, and
 * turn dedupe. Complements stop-lifecycle.test.ts (stop/abort flows).
 */
import { describe, expect, it, vi, beforeEach } from "vitest";
import { EventRing } from "../src/event-ring.js";
import { SessionManager, type ExtensionUIResponse } from "../src/sessions.js";
import { TurnDedupeCache } from "../src/turn-cache.js";
import type { GateServer } from "../src/gate.js";
import type { Storage } from "../src/storage.js";
import type { ServerConfig, ServerMessage, Session } from "../src/types.js";
import { makeSdkBackendStub } from "./sdk-backend.helpers.js";

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
    ...overrides,
  };
}

function makeManagerHarness(sessionOverrides: Partial<Session> = {}) {
  const storage = {
    getConfig: () => TEST_CONFIG,
    saveSession: vi.fn(),
    addSessionMessage: vi.fn(),
    getWorkspace: vi.fn(() => null),
  } as unknown as Storage;

  const gate = {
    destroySessionGuard: vi.fn(),
    getGuardState: vi.fn(() => "guarded"),
  } as unknown as GateServer;

  const manager = new SessionManager(storage, gate);

  // Disable idle timers for deterministic tests.
  (manager as unknown as { resetIdleTimer: (key: string) => void }).resetIdleTimer = () => {};

  const { sdkBackend, abort, dispose, prompt: sdkPrompt } = makeSdkBackendStub();
  const session = makeSession(sessionOverrides);

  // Inject active session directly into the manager.
  const active = {
    session,
    sdkBackend,
    workspaceId: session.workspaceId ?? "w1",
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

  return {
    manager,
    session,
    events,
    active,
    sdkBackend,
    sdkPrompt,
    abort,
    dispose,
    storage,
    gate,
  };
}

// Helper to call handlePiEvent which is private
function feedEvent(manager: SessionManager, key: string, data: unknown): void {
  (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
    key,
    data,
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
    feedEvent(manager, "s1", { type: "agent_end" });

    const result = manager.getCatchUp("s1", 0);
    expect(result!.currentSeq).toBeGreaterThan(0);
    expect(result!.events.length).toBeGreaterThan(0);
  });
});

// ─── Subscribe / Broadcast ───

describe("SessionManager subscribe", () => {
  it("subscriber receives broadcast events", () => {
    const { manager, events } = makeManagerHarness({ status: "busy" });

    feedEvent(manager, "s1", { type: "agent_end" });

    // Should receive state and agent_end messages
    expect(events.length).toBeGreaterThan(0);
  });

  it("unsubscribe stops delivery", () => {
    const { manager, session } = makeManagerHarness({ status: "busy" });

    const laterEvents: ServerMessage[] = [];
    const unsub = manager.subscribe("s1", (msg) => {
      laterEvents.push(msg);
    });

    feedEvent(manager, "s1", { type: "agent_end" });
    const countBeforeUnsub = laterEvents.length;

    unsub();

    // Re-set status to busy so we can trigger another event
    session.status = "busy";
    feedEvent(manager, "s1", { type: "agent_end" });

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

// RPC response correlation tests removed — SDK uses direct method calls.

// ─── Extension UI Protocol ───

describe("SessionManager extension UI", () => {
  it("forwards fire-and-forget notification methods", () => {
    const { manager, events } = makeManagerHarness();

    feedEvent(manager, "s1", {
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

    feedEvent(manager, "s1", {
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

  it("respondToUIRequest clears pending request", () => {
    const { manager, active } = makeManagerHarness();

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
    expect(gate.destroySessionGuard).toHaveBeenCalledWith("s1");
  });

  // pendingResponses removed — SDK uses direct method calls.

  it("clears pending UI requests on session end", () => {
    const { manager, active } = makeManagerHarness();

    active.pendingUIRequests.set("ui-10", {
      type: "extension_ui_request",
      id: "ui-10",
      method: "confirm",
    });

    (manager as unknown as { handleSessionEnd: (key: string, reason: string) => void })
      .handleSessionEnd("s1", "completed");

    expect(active.pendingUIRequests.size).toBe(0);
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

    feedEvent(manager, "s1", { type: "agent_start" });

    expect(session.status).toBe("busy");
  });

  it("agent_end sets session status to ready", () => {
    const { manager, session } = makeManagerHarness({ status: "busy" });

    feedEvent(manager, "s1", { type: "agent_end" });

    expect(session.status).toBe("ready");
  });

  it("text_delta via message_update broadcasts to subscribers", () => {
    const { manager, events } = makeManagerHarness({ status: "busy" });

    feedEvent(manager, "s1", {
      type: "message_update",
      assistantMessageEvent: { type: "text_delta", delta: "hello" },
    });

    expect(events.some((e) => e.type === "text_delta")).toBe(true);
  });

  it("tool_execution_start updates session change stats for write tool", () => {
    const { manager, session } = makeManagerHarness({ status: "busy" });

    feedEvent(manager, "s1", {
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

    feedEvent(manager, "s1", {
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
    feedEvent(manager, "s1", { type: "agent_end" });

    expect(session.lastActivity).toBeGreaterThanOrEqual(before);
  });
});

// ─── Prompt / Steer / Follow-up ───

describe("SessionManager prompt", () => {
  it("sends prompt to SDK backend", async () => {
    const { manager, sdkBackend } = makeManagerHarness({ status: "ready" });

    await manager.sendPrompt("s1", "hello world");

    expect(sdkBackend.prompt).toHaveBeenCalledWith("hello world", expect.objectContaining({}));
  });

  it("sends images with prompt", async () => {
    const { manager, sdkBackend } = makeManagerHarness({ status: "ready" });

    await manager.sendPrompt("s1", "look at this", {
      images: [{ type: "image", data: "base64data", mimeType: "image/png" }],
    });

    expect(sdkBackend.prompt).toHaveBeenCalledWith(
      "look at this",
      expect.objectContaining({
        images: [{ type: "image", data: "base64data", mimeType: "image/png" }],
      }),
    );
  });

  it("throws for nonexistent session", async () => {
    const { manager } = makeManagerHarness();
    await expect(manager.sendPrompt("nonexistent", "hi")).rejects.toThrow("not active");
  });

  it("deduplicates prompt with same clientTurnId", async () => {
    const { manager, sdkBackend, events } = makeManagerHarness({ status: "ready" });

    await manager.sendPrompt("s1", "hello", { clientTurnId: "turn-1" });
    const firstCallCount = (sdkBackend.prompt as ReturnType<typeof vi.fn>).mock.calls.length;

    await manager.sendPrompt("s1", "hello", { clientTurnId: "turn-1" });

    // Second call should NOT send another prompt
    expect((sdkBackend.prompt as ReturnType<typeof vi.fn>).mock.calls.length).toBe(firstCallCount);

    // Should get turn_ack events with duplicate flag
    const acks = events.filter((e) => e.type === "turn_ack");
    expect(acks.length).toBeGreaterThanOrEqual(2);
  });
});

describe("SessionManager steer", () => {
  it("sends steer command when busy", async () => {
    const { manager, sdkBackend } = makeManagerHarness({ status: "busy" });

    await manager.sendSteer("s1", "focus on X");

    expect(sdkBackend.prompt).toHaveBeenCalledWith(
      "focus on X",
      expect.objectContaining({ streamingBehavior: "steer" }),
    );
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
    const { manager, sdkBackend } = makeManagerHarness({ status: "busy" });

    await manager.sendFollowUp("s1", "also do Y");

    expect(sdkBackend.prompt).toHaveBeenCalledWith(
      "also do Y",
      expect.objectContaining({ streamingBehavior: "followUp" }),
    );
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

// RPC response dispatch tests removed — SDK uses direct method calls.

// ─── Event Translation & Broadcast ───

describe("handlePiEvent event translation", () => {
  it("broadcasts tool_execution_start event", () => {
    const { manager, events } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "tool_execution_start",
      toolName: "bash",
      toolCallId: "tc-1",
    });

    expect(events.some((e) => e.type === "tool_start")).toBe(true);
  });

  it("broadcasts tool_execution_end event", () => {
    const { manager, events } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "tool_execution_end",
      toolName: "bash",
      toolCallId: "tc-1",
    });

    expect(events.some((e) => e.type === "tool_end")).toBe(true);
  });

  it("broadcasts message_end with assistant content", () => {
    const { manager, events } = makeManagerHarness();

    feedEvent(manager, "s1", {
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

    feedEvent(manager, "s1", { type: "agent_start" });

    expect(session.status).toBe("busy");
  });

  it("updates session status to ready on agent_end", () => {
    const { manager, session } = makeManagerHarness();
    session.status = "busy";

    feedEvent(manager, "s1", { type: "agent_end" });

    expect(session.status).toBe("ready");
  });

  it("broadcasts state after status-changing events", () => {
    const { manager, events } = makeManagerHarness();

    feedEvent(manager, "s1", { type: "agent_start" });

    const stateEvents = events.filter((e) => e.type === "state");
    expect(stateEvents.length).toBeGreaterThanOrEqual(1);
  });

  it("broadcasts text_delta for message_update with text_delta", () => {
    const { manager, events } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "message_update",
      assistantMessageEvent: { type: "text_delta", delta: "hello " },
    });

    expect(events.some((e) => e.type === "text_delta")).toBe(true);
  });

  it("broadcasts thinking_delta for message_update with thinking_delta", () => {
    const { manager, events } = makeManagerHarness();

    feedEvent(manager, "s1", {
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

    feedEvent(manager, "s1", {
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

    feedEvent(manager, "s1", {
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

  it("respondToUIRequest clears pending request", () => {
    const { manager } = makeManagerHarness();

    // Set up a pending dialog
    feedEvent(manager, "s1", {
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
    feedEvent(manager, "s1", { type: "agent_start" });
    feedEvent(manager, "s1", { type: "text_delta", text: "hi" });
    feedEvent(manager, "s1", { type: "agent_end" });

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

    feedEvent(manager, "s1", {
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

    feedEvent(manager, "s1", {
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

    feedEvent(manager, "s1", {
      type: "message_end",
      message: {
        role: "assistant",
        content: [{ type: "text", text: "first" }],
        usage: { input: 100, output: 50, cacheRead: 0, cacheWrite: 0 },
      },
    });

    feedEvent(manager, "s1", {
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

    feedEvent(manager, "s1", { type: "agent_start" });

    expect(session.lastActivity).toBeGreaterThanOrEqual(before);
  });

  it("updates context tokens from message_end usage", () => {
    const { manager, session } = makeManagerHarness();

    feedEvent(manager, "s1", {
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

    feedEvent(manager, "s1", {
      type: "message_end",
      message: { role: "user", content: [{ type: "text", text: "hi" }] },
    });

    expect(session.messageCount).toBe(initialCount);
  });

  it("updates cost from message_end usage", () => {
    const { manager, session } = makeManagerHarness();

    feedEvent(manager, "s1", {
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
