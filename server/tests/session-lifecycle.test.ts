/**
 * Session lifecycle tests — state queries, RPC line handling, broadcast,
 * cleanup, prompt/steer/follow_up commands, extension UI protocol, and
 * turn dedupe. Complements stop-lifecycle.test.ts (stop/abort flows).
 */
import { mkdtemp, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import {
  EXTENSION_UI_STATUS_TEXT_MAX_CHARS,
  EXTENSION_UI_WORKING_INDICATOR_MAX_FRAME_CHARS,
  EXTENSION_UI_WORKING_INDICATOR_MAX_FRAMES,
  EXTENSION_UI_WORKING_MESSAGE_MAX_CHARS,
} from "../src/extension-ui-contract.js";
import { EventRing } from "../src/event-ring.js";
import { SdkBackend } from "../src/sdk-backend.js";
import { SessionManager, type ExtensionUIResponse } from "../src/sessions.js";
import {
  SessionLifecycleCoordinator,
  type SessionLifecycleCoordinatorDeps,
  type SessionLifecycleSessionState,
} from "../src/session-lifecycle.js";
import { TurnDedupeCache } from "../src/turn-cache.js";
import type { Storage } from "../src/storage.js";
import type { ServerConfig, ServerMessage, Session, Workspace } from "../src/types.js";
import { makeSdkBackendStub } from "./sdk-backend.helpers.js";

const TEST_CONFIG: ServerConfig = {
  port: 7749,
  host: "127.0.0.1",
  dataDir: "/tmp/oppi-lifecycle-tests",
  defaultModel: "anthropic/claude-sonnet-4-0",
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

function makeManagerHarness(
  sessionOverrides: Partial<Session> = {},
  options: { workspace?: Workspace } = {},
) {
  let sessionRef: Session | null = null;
  const storage = {
    getConfig: () => TEST_CONFIG,
    saveSession: vi.fn(),
    addSessionMessage: vi.fn(),
    getDataDir: vi.fn(() => TEST_CONFIG.dataDir),
    getWorkspace: vi.fn(() => options.workspace ?? null),
    getSession: vi.fn((id: string) => (sessionRef && sessionRef.id === id ? sessionRef : null)),
  } as unknown as Storage;

  const manager = new SessionManager(storage);

  // Disable idle timers for deterministic tests.
  (manager as unknown as { resetIdleTimer: (key: string) => void }).resetIdleTimer = () => {};

  const { sdkBackend, abort, dispose, prompt: sdkPrompt } = makeSdkBackendStub();
  const session = makeSession(sessionOverrides);
  sessionRef = session;

  // Inject active session directly into the manager.
  const active = {
    session,
    sdkBackend,
    workspaceId: session.workspaceId ?? "w1",
    subscribers: new Set<(msg: ServerMessage) => void>(),
    pendingUIRequests: new Map(),
    persistentExtensionUINotifications: new Map(),
    partialResults: new Map(),
    streamedAssistantText: "",
    hasStreamedThinking: false,
    streamedThinkingContentIndexes: new Set(),
    toolNames: new Map(),
    shellPreviewLastSent: new Map(),
    streamingArgPreviews: new Set(),
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
    session,
    events,
    active,
    sdkBackend,
    sdkPrompt,
    abort,
    dispose,
    storage,
  };
}

// Helper to call handlePiEvent which is private
function feedEvent(manager: SessionManager, key: string, data: unknown): void {
  (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
    key,
    data,
  );
}

afterEach(() => {
  vi.useRealTimers();
});

// ─── Session Startup ───

describe("SessionManager startSession", () => {
  it("resolves stored workspace when starting without an explicit workspace", async () => {
    const now = Date.now();
    const workspace: Workspace = {
      id: "w1",
      name: "Workspace",
      systemPromptMode: "append",
      hostMount: "/tmp/oppi-workspace-context-test",
      createdAt: now,
      updatedAt: now,
    };
    const session = makeSession({
      id: "session-1",
      workspaceId: workspace.id,
      workspaceName: workspace.name,
      status: "stopped",
    });
    const storage = {
      getConfig: () => TEST_CONFIG,
      getDataDir: vi.fn(() => TEST_CONFIG.dataDir),
      getSession: vi.fn((id: string) => (id === session.id ? session : null)),
      getWorkspace: vi.fn((id: string) => (id === workspace.id ? workspace : null)),
      listSessions: vi.fn(() => [session]),
      saveSession: vi.fn(),
    } as unknown as Storage;
    const { sdkBackend } = makeSdkBackendStub();
    const createSpy = vi.spyOn(SdkBackend, "create").mockResolvedValue(sdkBackend);
    const manager = new SessionManager(storage);
    (manager as unknown as { resetIdleTimer: (key: string) => void }).resetIdleTimer = () => {};

    try {
      await manager.startSession(session.id);

      expect(storage.getWorkspace).toHaveBeenCalledWith(workspace.id);
      expect(createSpy).toHaveBeenCalledWith(expect.objectContaining({ workspace }));
    } finally {
      createSpy.mockRestore();
    }
  });
});

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
      method: "setWidget",
      message: "Hello from extension",
      notifyType: "info",
      statusKey: "review",
      statusText: "running",
      title: "Review",
      text: "Act on findings",
      widgetKey: "review",
      widgetLines: ["Review active"],
      widgetPlacement: "aboveEditor",
    });

    const notif = events.find((e) => e.type === "extension_ui_notification");
    expect(notif).toEqual({
      type: "extension_ui_notification",
      method: "setWidget",
      message: "Hello from extension",
      notifyType: "info",
      statusKey: "review",
      statusText: "running",
      title: "Review",
      text: "Act on findings",
      widgetKey: "review",
      widgetLines: ["Review active"],
      widgetPlacement: "aboveEditor",
    });
  });

  it("replays the latest persistent fire-and-forget surfaces", () => {
    const { manager } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "status-1",
      method: "setStatus",
      statusKey: "review",
      statusText: "running",
    });
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "status-2",
      method: "setStatus",
      statusKey: "review",
      statusText: "done",
    });
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "widget-1",
      method: "setWidget",
      widgetKey: "agents",
      widgetLines: ["Agents active"],
      nativeSurface: {
        version: 1,
        id: "extension-picked-id",
        source: "widget",
        presentation: { style: "surfacePanel" },
        blocks: [{ type: "text", spans: [{ text: "Agents active" }] }],
      },
    });
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "title-1",
      method: "setTitle",
      title: "Review pass",
    });
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "notify-1",
      method: "notify",
      message: "Transient toast",
    });

    expect(manager.getPendingUIRequestMessages("s1")).toEqual([
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setStatus",
        statusKey: "review",
        statusText: "done",
      }),
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setWidget",
        widgetKey: "agents",
        widgetLines: ["Agents active"],
        nativeSurface: expect.objectContaining({
          id: "widget:agents",
          source: "widget",
        }),
      }),
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setTitle",
        title: "Review pass",
      }),
    ]);
  });

  it("replays widget replacements in Pi TUI order", () => {
    const { manager } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "widget-subagents-1",
      method: "setWidget",
      widgetKey: "subagents",
      widgetLines: ["Agents active"],
    });
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "widget-goal-1",
      method: "setWidget",
      widgetKey: "goal",
      widgetLines: ["Goal active"],
    });
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "widget-subagents-2",
      method: "setWidget",
      widgetKey: "subagents",
      widgetLines: ["Agents updated"],
    });

    const pendingWidgets = manager
      .getPendingUIRequestMessages("s1")
      .filter(
        (message): message is Extract<ServerMessage, { type: "extension_ui_notification" }> =>
          message.type === "extension_ui_notification",
      );
    expect(pendingWidgets.map((message) => message.widgetKey)).toEqual(["goal", "subagents"]);
    expect(pendingWidgets.at(-1)).toMatchObject({
      method: "setWidget",
      widgetKey: "subagents",
      widgetLines: ["Agents updated"],
    });
  });

  it("replays explicit clears for persistent fire-and-forget surfaces", () => {
    const { manager } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "status-1",
      method: "setStatus",
      statusKey: "review",
      statusText: "running",
    });
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "widget-1",
      method: "setWidget",
      widgetKey: "agents",
      widgetLines: ["Agents active"],
    });
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "title-1",
      method: "setTitle",
      title: "Review pass",
    });

    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "status-clear",
      method: "setStatus",
      statusKey: "review",
      statusText: " ",
    });
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "widget-clear",
      method: "setWidget",
      widgetKey: "agents",
      widgetLines: [],
    });
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "title-clear",
      method: "setTitle",
      title: "",
    });

    expect(manager.getPendingUIRequestMessages("s1")).toEqual([
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setStatus",
        statusKey: "review",
        statusText: undefined,
      }),
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setWidget",
        widgetKey: "agents",
        widgetLines: undefined,
      }),
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setTitle",
        title: undefined,
      }),
    ]);
  });

  it("replays status notifications by key without name-specific filtering", () => {
    const { manager, events } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "status-1",
      method: "setStatus",
      statusKey: "extension-status",
      statusText: "connected",
    });

    expect(events.at(-1)).toMatchObject({
      type: "extension_ui_notification",
      method: "setStatus",
      statusKey: "extension-status",
      statusText: "connected",
    });
    expect(manager.getPendingUIRequestMessages("s1")).toEqual([
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setStatus",
        statusKey: "extension-status",
        statusText: "connected",
      }),
    ]);
  });

  it("throttles high-frequency working messages while retaining the latest replay state", () => {
    vi.useFakeTimers();
    vi.setSystemTime(1_000);
    const { manager, events } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "working-message-1",
      method: "setWorkingMessage",
      message: "Indexing files",
    });
    vi.setSystemTime(1_100);
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "working-message-2",
      method: "setWorkingMessage",
      message: "Checking tests",
    });

    expect(
      events.filter(
        (event) =>
          event.type === "extension_ui_notification" && event.method === "setWorkingMessage",
      ),
    ).toHaveLength(1);
    expect(manager.getPendingUIRequestMessages("s1")).toContainEqual(
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setWorkingMessage",
        message: "Checking tests",
      }),
    );

    vi.setSystemTime(1_251);
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "working-message-3",
      method: "setWorkingMessage",
      message: "Reading diffs",
    });

    expect(
      events.filter(
        (event) =>
          event.type === "extension_ui_notification" && event.method === "setWorkingMessage",
      ),
    ).toHaveLength(2);

    vi.setSystemTime(1_300);
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "working-message-clear",
      method: "setWorkingMessage",
      message: " ",
    });

    expect(events.at(-1)).toMatchObject({
      type: "extension_ui_notification",
      method: "setWorkingMessage",
      message: " ",
    });
  });

  it("throttles high-frequency working messages and flushes the latest value", () => {
    vi.useFakeTimers();
    vi.setSystemTime(1_000);
    const { manager, events } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "working-message-1",
      method: "setWorkingMessage",
      message: "Indexing files",
    });
    vi.setSystemTime(1_100);
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "working-message-2",
      method: "setWorkingMessage",
      message: "Checking tests",
    });

    const workingMessageEvents = () =>
      events.filter(
        (event) =>
          event.type === "extension_ui_notification" && event.method === "setWorkingMessage",
      );

    expect(workingMessageEvents()).toHaveLength(1);
    vi.advanceTimersByTime(150);
    expect(workingMessageEvents()).toHaveLength(2);
    expect(events.at(-1)).toMatchObject({
      type: "extension_ui_notification",
      method: "setWorkingMessage",
      message: "Checking tests",
    });
  });

  it("throttles high-frequency status updates by key and flushes the latest value", () => {
    vi.useFakeTimers();
    vi.setSystemTime(2_000);
    const { manager, events } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "status-1",
      method: "setStatus",
      statusKey: "working-words",
      statusText: "phrase 1",
    });
    vi.setSystemTime(2_100);
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "status-2",
      method: "setStatus",
      statusKey: "working-words",
      statusText: "phrase 2",
    });

    const statusEvents = () =>
      events.filter(
        (event) =>
          event.type === "extension_ui_notification" &&
          event.method === "setStatus" &&
          event.statusKey === "working-words",
      );

    expect(statusEvents()).toHaveLength(1);
    expect(manager.getPendingUIRequestMessages("s1")).toContainEqual(
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setStatus",
        statusKey: "working-words",
        statusText: "phrase 2",
      }),
    );

    vi.advanceTimersByTime(149);
    expect(statusEvents()).toHaveLength(1);

    vi.advanceTimersByTime(1);
    expect(statusEvents()).toHaveLength(2);
    expect(events.at(-1)).toMatchObject({
      type: "extension_ui_notification",
      method: "setStatus",
      statusKey: "working-words",
      statusText: "phrase 2",
    });
  });

  it("cancels a throttled status update when the value returns to the last emitted state", () => {
    vi.useFakeTimers();
    vi.setSystemTime(2_000);
    const { manager, events } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "status-1",
      method: "setStatus",
      statusKey: "working-words",
      statusText: "phrase 1",
    });
    vi.setSystemTime(2_100);
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "status-2",
      method: "setStatus",
      statusKey: "working-words",
      statusText: "phrase 2",
    });
    vi.setSystemTime(2_150);
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "status-3",
      method: "setStatus",
      statusKey: "working-words",
      statusText: "phrase 1",
    });

    const statusEvents = () =>
      events.filter(
        (event) =>
          event.type === "extension_ui_notification" &&
          event.method === "setStatus" &&
          event.statusKey === "working-words",
      );

    expect(statusEvents()).toHaveLength(1);
    vi.advanceTimersByTime(250);
    expect(statusEvents()).toHaveLength(1);
    expect(manager.getPendingUIRequestMessages("s1")).toContainEqual(
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setStatus",
        statusKey: "working-words",
        statusText: "phrase 1",
      }),
    );
  });

  it("does not replay a throttled status update after a clear", () => {
    vi.useFakeTimers();
    vi.setSystemTime(2_000);
    const { manager, events } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "status-1",
      method: "setStatus",
      statusKey: "working-words",
      statusText: "phrase 1",
    });
    vi.setSystemTime(2_100);
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "status-2",
      method: "setStatus",
      statusKey: "working-words",
      statusText: "phrase 2",
    });
    vi.setSystemTime(2_150);
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "status-clear",
      method: "setStatus",
      statusKey: "working-words",
      statusText: " ",
    });

    const statusEvents = () =>
      events.filter(
        (event) =>
          event.type === "extension_ui_notification" &&
          event.method === "setStatus" &&
          event.statusKey === "working-words",
      );

    expect(statusEvents()).toHaveLength(2);
    expect(events.at(-1)).toMatchObject({
      type: "extension_ui_notification",
      method: "setStatus",
      statusKey: "working-words",
      statusText: " ",
    });

    vi.advanceTimersByTime(250);
    expect(statusEvents()).toHaveLength(2);
  });

  it("stores bounded persistent extension UI payloads", () => {
    const { manager, active } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "working-message-large",
      method: "setWorkingMessage",
      message: "w".repeat(EXTENSION_UI_WORKING_MESSAGE_MAX_CHARS + 20),
    });

    expect(active.persistentExtensionUINotifications.get("working:message")?.message).toHaveLength(
      EXTENSION_UI_WORKING_MESSAGE_MAX_CHARS,
    );

    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "status-large",
      method: "setStatus",
      statusKey: "working-words",
      statusText: "s".repeat(EXTENSION_UI_STATUS_TEXT_MAX_CHARS + 20),
    });

    expect(
      active.persistentExtensionUINotifications.get("status:working-words")?.statusText,
    ).toHaveLength(EXTENSION_UI_STATUS_TEXT_MAX_CHARS);

    const longFrame = "x".repeat(EXTENSION_UI_WORKING_INDICATOR_MAX_FRAME_CHARS + 20);
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "working-indicator-large",
      method: "setWorkingIndicator",
      workingIndicator: {
        frames: Array.from(
          { length: EXTENSION_UI_WORKING_INDICATOR_MAX_FRAMES + 10 },
          (_, index) => `${longFrame}${index}`,
        ),
        intervalMs: 1,
      },
    });

    const storedIndicator = active.persistentExtensionUINotifications.get("working:indicator")
      ?.workingIndicator as { frames?: string[] } | undefined;
    expect(storedIndicator?.frames).toHaveLength(EXTENSION_UI_WORKING_INDICATOR_MAX_FRAMES);
    expect(storedIndicator?.frames?.[0]).toHaveLength(
      EXTENSION_UI_WORKING_INDICATOR_MAX_FRAME_CHARS,
    );
  });

  it("throttles high-frequency working indicators without dropping hidden state", () => {
    vi.useFakeTimers();
    vi.setSystemTime(3_000);
    const { manager, events } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "working-indicator-1",
      method: "setWorkingIndicator",
      workingIndicator: { frames: ["·", "•"], intervalMs: 120 },
    });
    vi.setSystemTime(3_100);
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "working-indicator-2",
      method: "setWorkingIndicator",
      workingIndicator: { frames: ["◐", "◓"], intervalMs: 90 },
    });

    const indicatorEvents = () =>
      events.filter(
        (event) =>
          event.type === "extension_ui_notification" && event.method === "setWorkingIndicator",
      );

    expect(indicatorEvents()).toHaveLength(1);
    expect(manager.getPendingUIRequestMessages("s1")).toContainEqual(
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setWorkingIndicator",
        workingIndicator: { frames: ["◐", "◓"], intervalMs: 90 },
      }),
    );

    vi.setSystemTime(3_150);
    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "working-indicator-hidden",
      method: "setWorkingIndicator",
      workingIndicator: { frames: [], intervalMs: 120 },
    });

    expect(indicatorEvents()).toHaveLength(2);
    expect(events.at(-1)).toMatchObject({
      type: "extension_ui_notification",
      method: "setWorkingIndicator",
      workingIndicator: { frames: [], intervalMs: 120 },
    });
  });

  it("tracks dialog methods as pending UI requests", () => {
    const { manager, events, active } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "ui-2",
      method: "confirm",
      title: "Pick an option",
    });

    expect(active.pendingUIRequests.has("ui-2")).toBe(true);
    const uiReq = events.find((e) => e.type === "extension_ui_request");
    expect(uiReq).toBeDefined();
  });

  it("respondToUIRequest clears pending request and broadcasts settled", () => {
    const { manager, active, sdkBackend, events } = makeManagerHarness();

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
    expect(sdkBackend.respondToExtensionUIRequest).toHaveBeenCalledWith(response);
    expect(active.pendingUIRequests.has("ui-3")).toBe(false);
    expect(events.at(-1)).toEqual({ type: "extension_ui_settled", id: "ui-3", sessionId: "s1" });
  });

  it("respondToUIRequest keeps pending request when the SDK bridge rejects delivery", () => {
    const { manager, active, sdkBackend } = makeManagerHarness();
    vi.mocked(sdkBackend.respondToExtensionUIRequest).mockReturnValueOnce(false);

    active.pendingUIRequests.set("ui-undelivered", {
      type: "extension_ui_request",
      id: "ui-undelivered",
      method: "confirm",
      title: "Are you sure?",
    });

    const result = manager.respondToUIRequest("s1", {
      type: "extension_ui_response",
      id: "ui-undelivered",
      confirmed: true,
    });

    expect(result).toBe(false);
    expect(active.pendingUIRequests.has("ui-undelivered")).toBe(true);
  });

  it("clears settled extension UI requests so they are not replayed", () => {
    const { manager, active } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "ui-settled",
      method: "confirm",
      title: "Are you sure?",
      timeout: 1_000,
      timeoutAt: Date.now() + 1_000,
    });
    expect(active.pendingUIRequests.has("ui-settled")).toBe(true);

    feedEvent(manager, "s1", {
      type: "extension_ui_request_settled",
      id: "ui-settled",
    });

    expect(active.pendingUIRequests.has("ui-settled")).toBe(false);
    expect(manager.getPendingUIRequestMessages("s1")).toEqual([]);
  });

  it("does not replay request-side native surfaces for blocking extension UI", () => {
    const { manager } = makeManagerHarness();

    feedEvent(manager, "s1", {
      type: "extension_ui_request",
      id: "ui-native",
      method: "editor",
      title: "Edit plan",
      nativeSurface: {
        version: 1,
        id: "request:plan-editor",
        source: "widget",
        presentation: { style: "surfacePanel", title: "Edit plan" },
        blocks: [{ type: "text", spans: [{ text: "Review before submitting." }] }],
      },
    });

    const [message] = manager.getPendingUIRequestMessages("s1");
    expect(message).toMatchObject({
      type: "extension_ui_request",
      id: "ui-native",
      sessionId: "s1",
    });
    expect("nativeSurface" in (message as Record<string, unknown>)).toBe(false);
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
  it("cleans up resources on session end", async () => {
    const { manager, events } = makeManagerHarness();

    // Trigger handleSessionEnd (async since dispose() became awaitable)
    await (
      manager as unknown as { handleSessionEnd: (key: string, reason: string) => Promise<void> }
    ).handleSessionEnd("s1", "completed");

    expect(events.some((e) => e.type === "session_ended")).toBe(true);
    expect(manager.isActive("s1")).toBe(false);
  });

  // pendingResponses removed — SDK uses direct method calls.

  it("clears pending UI requests on session end", () => {
    const { manager, active } = makeManagerHarness();

    active.pendingUIRequests.set("ui-10", {
      type: "extension_ui_request",
      id: "ui-10",
      method: "confirm",
    });

    (
      manager as unknown as { handleSessionEnd: (key: string, reason: string) => void }
    ).handleSessionEnd("s1", "completed");

    expect(active.pendingUIRequests.size).toBe(0);
  });

  it("saves session with stopped status", () => {
    const { manager, session, storage } = makeManagerHarness();

    (
      manager as unknown as { handleSessionEnd: (key: string, reason: string) => void }
    ).handleSessionEnd("s1", "completed");

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

  it("does not reindex search on live message_end", () => {
    const { manager } = makeManagerHarness({ status: "busy" });
    const markForReindex = vi.fn();
    const flushForSession = vi.fn();
    const indexSession = vi.fn();
    const deleteSession = vi.fn();
    manager.searchIndex = { markForReindex, flushForSession, indexSession, deleteSession };

    feedEvent(manager, "s1", {
      type: "message_end",
      message: {
        role: "assistant",
        content: [{ type: "text", text: "indexed" }],
      },
    });

    expect(markForReindex).not.toHaveBeenCalled();
    expect(flushForSession).not.toHaveBeenCalled();
  });

  it("marks and flushes search reindex on agent_end", () => {
    const { manager } = makeManagerHarness({ status: "busy" });
    const markForReindex = vi.fn();
    const flushForSession = vi.fn();
    const indexSession = vi.fn();
    const deleteSession = vi.fn();
    manager.searchIndex = { markForReindex, flushForSession, indexSession, deleteSession };

    feedEvent(manager, "s1", { type: "agent_end" });

    expect(markForReindex).toHaveBeenCalledWith("s1");
    expect(flushForSession).toHaveBeenCalledWith("s1");
  });

  it("removes ephemeral sessions from search index instead of reindexing", () => {
    const { manager } = makeManagerHarness({ status: "busy", ephemeral: true });
    const markForReindex = vi.fn();
    const flushForSession = vi.fn();
    const indexSession = vi.fn();
    const deleteSession = vi.fn();
    manager.searchIndex = { markForReindex, flushForSession, indexSession, deleteSession };

    feedEvent(manager, "s1", {
      type: "message_end",
      message: { role: "assistant", content: [{ type: "text", text: "ignored" }] },
    });

    expect(deleteSession).toHaveBeenCalledWith("s1");
    expect(markForReindex).not.toHaveBeenCalled();
    expect(flushForSession).not.toHaveBeenCalled();
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

  it("materializes image attachments before sending a prompt", async () => {
    const workspaceRoot = await mkdtemp(join(tmpdir(), "oppi-prompt-image-"));
    const imageBytes = Buffer.from("base64data");
    await writeFile(join(workspaceRoot, "screenshot.png"), imageBytes);
    const workspace: Workspace = {
      id: "w1",
      name: "test",
      systemPromptMode: "append",
      hostMount: workspaceRoot,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    const { manager, sdkBackend } = makeManagerHarness({ status: "ready" }, { workspace });

    await manager.sendPrompt("s1", "look at this", {
      attachments: [
        {
          type: "attachment",
          id: "att-image",
          source: "workspace",
          name: "screenshot.png",
          mimeType: "image/png",
          sizeBytes: imageBytes.byteLength,
          workspacePath: "screenshot.png",
        },
      ],
    });

    expect(sdkBackend.prompt).toHaveBeenCalledWith(
      expect.stringContaining("Attached files:\n- screenshot.png:"),
      expect.objectContaining({
        images: [{ type: "image", data: imageBytes.toString("base64"), mimeType: "image/png" }],
      }),
    );
  });

  it("forwards busy prompt streamingBehavior to SDK", async () => {
    const { manager, sdkBackend } = makeManagerHarness({ status: "busy" });

    await manager.sendPrompt("s1", "interrupt", { streamingBehavior: "steer" });

    expect(sdkBackend.prompt).toHaveBeenCalledWith(
      "interrupt",
      expect.objectContaining({ streamingBehavior: "steer" }),
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

    await expect(manager.sendSteer("s1", "focus")).rejects.toThrow("active streaming turn");
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

    await expect(manager.sendFollowUp("s1", "more")).rejects.toThrow("active streaming turn");
  });
});

describe("SessionManager message queue", () => {
  it("tracks steering and follow-up queue state", async () => {
    const { manager } = makeManagerHarness({ status: "busy" });

    await manager.sendSteer("s1", "first steer", { clientTurnId: "turn-steer-1" });
    await manager.sendFollowUp("s1", "first follow", { clientTurnId: "turn-follow-1" });

    const queue = manager.getMessageQueue("s1");
    expect(queue.version).toBeGreaterThan(0);
    expect(queue.steering.map((item) => item.message)).toEqual(["first steer"]);
    expect(queue.followUp.map((item) => item.message)).toEqual(["first follow"]);
  });

  it("reconciles queue state from SDK when user message starts", async () => {
    const { manager, sdkBackend, events } = makeManagerHarness({ status: "busy" });

    await manager.sendSteer("s1", "queued steer", { clientTurnId: "turn-steer-1" });
    const before = manager.getMessageQueue("s1");
    expect(before.steering.map((item) => item.message)).toEqual(["queued steer"]);

    sdkBackend.session.clearQueue();

    // Simulate a user message_start payload shape that does not expose text
    // in a directly parseable block type. Coordinator should still reconcile
    // by diffing against SDK queue state.
    feedEvent(manager, "s1", {
      type: "message_start",
      message: {
        role: "user",
        content: [{ type: "unknown_text_block", text: "queued steer" }],
      },
    });

    const after = manager.getMessageQueue("s1");
    expect(after.steering).toHaveLength(0);
    expect(after.followUp).toHaveLength(0);
    expect(after.version).toBeGreaterThan(before.version);

    const started = events.filter((event) => event.type === "queue_item_started");
    expect(started).toHaveLength(1);
    expect(started[0]).toMatchObject({
      type: "queue_item_started",
      kind: "steer",
      item: expect.objectContaining({ message: "queued steer" }),
    });
  });

  it("reconciles queue state from SDK when turn starts without user message_start", async () => {
    const { manager, sdkBackend, events } = makeManagerHarness({ status: "busy" });

    await manager.sendSteer("s1", "queued steer", { clientTurnId: "turn-steer-2" });
    const before = manager.getMessageQueue("s1");
    expect(before.steering.map((item) => item.message)).toEqual(["queued steer"]);

    sdkBackend.session.clearQueue();

    feedEvent(manager, "s1", {
      type: "turn_start",
      turnId: "t-queue-reconcile",
      timestamp: Date.now(),
    });

    const after = manager.getMessageQueue("s1");
    expect(after.steering).toHaveLength(0);
    expect(after.followUp).toHaveLength(0);
    expect(after.version).toBeGreaterThan(before.version);

    const started = events.filter((event) => event.type === "queue_item_started");
    expect(started).toHaveLength(1);
    expect(started[0]).toMatchObject({
      type: "queue_item_started",
      kind: "steer",
      item: expect.objectContaining({ message: "queued steer" }),
    });
  });

  it("replaces queue using optimistic version check", async () => {
    const { manager, sdkBackend } = makeManagerHarness({ status: "busy" });
    (sdkBackend as { isStreaming: boolean }).isStreaming = true;

    await manager.sendSteer("s1", "old steer", { clientTurnId: "turn-old-steer" });
    const before = manager.getMessageQueue("s1");

    const after = await manager.setMessageQueue("s1", {
      baseVersion: before.version,
      steering: [{ id: "new-steer", message: "new steer" }],
      followUp: [{ id: "new-follow", message: "new follow" }],
    });

    expect(sdkBackend.session.clearQueue).toHaveBeenCalledTimes(1);
    expect(sdkBackend.session.steer).toHaveBeenCalledWith("new steer", undefined);
    expect(sdkBackend.session.followUp).toHaveBeenCalledWith("new follow", undefined);
    expect(after.steering.map((item) => item.message)).toEqual(["new steer"]);
    expect(after.followUp.map((item) => item.message)).toEqual(["new follow"]);
  });

  it("flushes stale follow-up queue after compaction leaves the SDK idle", async () => {
    vi.useFakeTimers();
    const { manager, sdkBackend, sdkPrompt, events } = makeManagerHarness({ status: "busy" });

    await manager.sendFollowUp("s1", "continue 1", { clientTurnId: "turn-follow-1" });
    await manager.sendFollowUp("s1", "continue 2", { clientTurnId: "turn-follow-2" });
    await manager.sendFollowUp("s1", "continue 3", { clientTurnId: "turn-follow-3" });
    sdkPrompt.mockClear();
    (sdkBackend.session.clearQueue as ReturnType<typeof vi.fn>).mockClear();

    feedEvent(manager, "s1", {
      type: "compaction_end",
      reason: "threshold",
      result: undefined,
      aborted: false,
      willRetry: false,
    });

    await vi.advanceTimersByTimeAsync(300);

    expect(sdkBackend.session.clearQueue).toHaveBeenCalledTimes(1);
    expect(sdkPrompt).toHaveBeenCalledTimes(1);
    expect(sdkPrompt.mock.calls[0]?.[0]).toBe("continue 1");
    expect(sdkPrompt.mock.calls[0]?.[1]?.streamingBehavior).toBeUndefined();
    expect(sdkBackend.session.getFollowUpMessages()).toEqual(["continue 2", "continue 3"]);

    const after = manager.getMessageQueue("s1");
    expect(after.followUp.map((item) => item.message)).toEqual(["continue 2", "continue 3"]);
    expect(events).toContainEqual(
      expect.objectContaining({
        type: "queue_item_started",
        kind: "follow_up",
        item: expect.objectContaining({ message: "continue 1" }),
      }),
    );
  });

  it("saves and flushes an edited stale queue while idle", async () => {
    const { manager, session, sdkBackend, sdkPrompt } = makeManagerHarness({ status: "busy" });

    (sdkBackend as { isStreaming: boolean }).isStreaming = true;
    await manager.sendFollowUp("s1", "old follow", { clientTurnId: "turn-old-follow" });
    const before = manager.getMessageQueue("s1");

    (sdkBackend as { isStreaming: boolean }).isStreaming = false;
    session.status = "ready";
    sdkPrompt.mockClear();

    const after = await manager.setMessageQueue("s1", {
      baseVersion: before.version,
      steering: [],
      followUp: [
        { id: "new-follow-1", message: "new follow 1" },
        { id: "new-follow-2", message: "new follow 2" },
      ],
    });

    expect(sdkPrompt).toHaveBeenCalledTimes(1);
    expect(sdkPrompt.mock.calls[0]?.[0]).toBe("new follow 1");
    expect(after.followUp.map((item) => item.message)).toEqual(["new follow 2"]);
    expect(sdkBackend.session.getFollowUpMessages()).toEqual(["new follow 2"]);
  });

  it("keeps queued attachment state raw after busy send and unchanged queue save", async () => {
    const workspaceRoot = await mkdtemp(join(tmpdir(), "oppi-busy-queue-attachments-"));
    await writeFile(join(workspaceRoot, "note.txt"), "hello from queue");
    const workspace: Workspace = {
      id: "w1",
      name: "test",
      systemPromptMode: "append",
      hostMount: workspaceRoot,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    const { manager, sdkBackend } = makeManagerHarness({ status: "busy" }, { workspace });
    (sdkBackend as { isStreaming: boolean }).isStreaming = true;

    await manager.sendSteer("s1", "read this", {
      clientTurnId: "turn-busy-file",
      attachments: [
        {
          type: "attachment",
          id: "att-note",
          source: "workspace",
          name: "note.txt",
          mimeType: "text/plain",
          sizeBytes: 16,
          workspacePath: "note.txt",
        },
      ],
    });

    const queued = manager.getMessageQueue("s1");
    expect(queued.steering[0]?.message).toBe("read this");
    expect(queued.steering[0]?.attachments?.[0]?.id).toBe("att-note");

    const saved = await manager.setMessageQueue("s1", {
      baseVersion: queued.version,
      steering: queued.steering,
      followUp: queued.followUp,
    });

    const lastPromptMessage = (sdkBackend.prompt as ReturnType<typeof vi.fn>).mock.calls.at(
      -1,
    )?.[0] as string;
    const savedSteerMessage = (sdkBackend.session.steer as ReturnType<typeof vi.fn>).mock.calls.at(
      -1,
    )?.[0] as string;
    expect(lastPromptMessage.match(/Attached files:/g)).toHaveLength(1);
    expect(savedSteerMessage.match(/Attached files:/g)).toHaveLength(1);
    expect(saved.steering[0]?.message).toBe("read this");
  });

  it("keeps materialized image bytes out of public queue state", async () => {
    const workspaceRoot = await mkdtemp(join(tmpdir(), "oppi-busy-queue-image-"));
    const imageBytes = Buffer.from("fake image bytes that stand in for a large screenshot");
    await writeFile(join(workspaceRoot, "screenshot.jpg"), imageBytes);
    const workspace: Workspace = {
      id: "w1",
      name: "test",
      systemPromptMode: "append",
      hostMount: workspaceRoot,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    const { manager, sdkBackend } = makeManagerHarness({ status: "busy" }, { workspace });
    (sdkBackend as { isStreaming: boolean }).isStreaming = true;

    await manager.sendSteer("s1", "", {
      clientTurnId: "turn-busy-image",
      attachments: [
        {
          type: "attachment",
          id: "att-image",
          source: "workspace",
          name: "screenshot.jpg",
          mimeType: "image/jpeg",
          sizeBytes: imageBytes.byteLength,
          workspacePath: "screenshot.jpg",
        },
      ],
    });

    const queued = manager.getMessageQueue("s1");
    expect(queued.steering[0]?.attachments?.[0]?.id).toBe("att-image");
    expect(JSON.stringify(queued)).not.toContain(imageBytes.toString("base64").slice(0, 16));

    await manager.setMessageQueue("s1", {
      baseVersion: queued.version,
      steering: queued.steering,
      followUp: queued.followUp,
    });

    expect(sdkBackend.session.steer).toHaveBeenCalledWith(
      expect.stringContaining("Attached files:\n- screenshot.jpg:"),
      [
        expect.objectContaining({
          type: "image",
          data: imageBytes.toString("base64"),
          mimeType: "image/jpeg",
        }),
      ],
    );
  });

  it("keeps large queued image broadcasts below websocket payload limits", async () => {
    const workspaceRoot = await mkdtemp(join(tmpdir(), "oppi-busy-queue-large-image-"));
    const imageBytes = Buffer.alloc(1_200_000, 0x5a);
    await writeFile(join(workspaceRoot, "large-screenshot.jpg"), imageBytes);
    const workspace: Workspace = {
      id: "w1",
      name: "test",
      systemPromptMode: "append",
      hostMount: workspaceRoot,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    const { manager, events } = makeManagerHarness({ status: "busy" }, { workspace });

    await manager.sendSteer("s1", "", {
      clientTurnId: "turn-large-image",
      attachments: [
        {
          type: "attachment",
          id: "att-large-image",
          source: "workspace",
          name: "large-screenshot.jpg",
          mimeType: "image/jpeg",
          sizeBytes: imageBytes.byteLength,
          workspacePath: "large-screenshot.jpg",
        },
      ],
    });

    const queueEvent = events.filter((event) => event.type === "queue_state").at(-1);
    expect(queueEvent).toBeDefined();

    const serialized = JSON.stringify(queueEvent);
    const base64Prefix = imageBytes.toString("base64").slice(0, 64);
    expect(serialized).not.toContain(base64Prefix);
    expect(serialized.length).toBeLessThan(16 * 1024);
  });

  it("materializes attachments when replacing queue", async () => {
    const workspaceRoot = await mkdtemp(join(tmpdir(), "oppi-queue-attachments-"));
    await writeFile(join(workspaceRoot, "note.txt"), "hello from queue");
    const workspace: Workspace = {
      id: "w1",
      name: "test",
      systemPromptMode: "append",
      hostMount: workspaceRoot,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    const { manager, sdkBackend } = makeManagerHarness({ status: "busy" }, { workspace });
    (sdkBackend as { isStreaming: boolean }).isStreaming = true;

    const before = manager.getMessageQueue("s1");
    const after = await manager.setMessageQueue("s1", {
      baseVersion: before.version,
      steering: [
        {
          id: "turn-with-file",
          message: "read this",
          attachments: [
            {
              type: "attachment",
              id: "att-note",
              source: "workspace",
              name: "note.txt",
              mimeType: "text/plain",
              sizeBytes: 16,
              workspacePath: "note.txt",
            },
          ],
        },
      ],
      followUp: [],
    });

    expect(sdkBackend.session.steer).toHaveBeenCalledWith(
      expect.stringContaining(
        "Attached files:\n- note.txt: .pi/attachments/s1/turn-with-file/note.txt",
      ),
      undefined,
    );
    expect(after.steering[0]).toMatchObject({
      id: "turn-with-file",
      message: "read this",
      attachments: [expect.objectContaining({ id: "att-note" })],
    });

    const second = await manager.setMessageQueue("s1", {
      baseVersion: after.version,
      steering: after.steering,
      followUp: after.followUp,
    });

    const secondSteerCall = (sdkBackend.session.steer as ReturnType<typeof vi.fn>).mock.calls.at(
      -1,
    );
    const secondMessage = secondSteerCall?.[0] as string;
    expect(secondMessage.match(/Attached files:/g)).toHaveLength(1);
    expect(second.steering[0]?.message).toBe("read this");
  });

  it("rejects stale queue replacement versions", async () => {
    const { manager, sdkBackend } = makeManagerHarness({ status: "busy" });
    (sdkBackend as { isStreaming: boolean }).isStreaming = true;

    await manager.sendSteer("s1", "baseline", { clientTurnId: "turn-baseline" });
    const current = manager.getMessageQueue("s1");

    await expect(
      manager.setMessageQueue("s1", {
        baseVersion: current.version - 1,
        steering: [],
        followUp: [],
      }),
    ).rejects.toThrow("Queue version mismatch");
  });
});

// ─── RPC Passthrough ───

describe("SessionManager RPC passthrough", () => {
  it("rejects non-allowlisted commands", async () => {
    const { manager } = makeManagerHarness();

    await expect(manager.forwardClientCommand("s1", { type: "evil_command" })).rejects.toThrow(
      "oppi runtime does not support command: evil_command",
    );
  });

  it("throws for nonexistent session", async () => {
    const { manager } = makeManagerHarness();

    await expect(
      manager.forwardClientCommand("nonexistent", { type: "get_state" }),
    ).rejects.toThrow("not active");
  });
});

// ─── SDK state bootstrap/refresh ───

describe("SessionManager SDK state bootstrap", () => {
  it("uses getStateSnapshot model/provider to resolve context window", async () => {
    const { manager, session, sdkBackend } = makeManagerHarness();

    manager.contextWindowResolver = (modelId: string) =>
      modelId === "openai-codex/gpt-5.3-codex" ? 272_000 : 200_000;

    (sdkBackend.getStateSnapshot as ReturnType<typeof vi.fn>).mockReturnValue({
      model: { provider: "openai-codex", id: "gpt-5.3-codex" },
      thinkingLevel: "medium",
      isStreaming: false,
    });

    await (
      manager as unknown as {
        bootstrapSessionState: (key: string) => Promise<void>;
      }
    ).bootstrapSessionState("s1");

    expect(session.model).toBe("openai-codex/gpt-5.3-codex");
    expect(session.contextWindow).toBe(272_000);
    expect(sdkBackend.getStateSnapshot).toHaveBeenCalledTimes(1);
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

  it("broadcasts session summary after status-changing events", () => {
    const { manager, events } = makeManagerHarness();

    feedEvent(manager, "s1", { type: "agent_start" });

    const summaryEvents = events.filter((e) => e.type === "session_summary");
    expect(summaryEvents.length).toBeGreaterThanOrEqual(1);
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
      method: "confirm",
      title: "Pick one",
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

// ─── SessionLifecycleCoordinator direct coverage ───

// ─── Factories ───

function makeLifecycleSession(overrides?: Partial<Session>): Session {
  return {
    id: "session-1",
    status: "ready",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeLifecycleActiveSession(overrides?: Partial<Session>): SessionLifecycleSessionState {
  const session = makeLifecycleSession(overrides);
  return {
    session,
    sdkBackend: {
      isDisposed: false,
      dispose: vi.fn(),
      onShutdownCleanupComplete: vi.fn(),
    } as never,
    workspaceId: "ws-1",
    pendingUIRequests: new Map(),
  };
}

function makeLifecycleDeps(
  active: SessionLifecycleSessionState | undefined,
  overrides?: Partial<SessionLifecycleCoordinatorDeps>,
): SessionLifecycleCoordinatorDeps {
  return {
    getActiveSession: vi.fn(() => active),
    removeActiveSession: vi.fn(),
    clearPendingStop: vi.fn(() => null),
    broadcast: vi.fn(),
    persistSessionNow: vi.fn(),
    releaseSession: vi.fn(),
    stopSession: vi.fn(async () => {}),
    getSessionIdleTimeoutMs: () => 300_000,
    ...overrides,
  };
}

// ─── Tests ───

describe("SessionLifecycleCoordinator.handleSessionEnd", () => {
  it("tears down immediately and disposes the backend", async () => {
    const order: string[] = [];
    const active = makeLifecycleActiveSession();

    active.sdkBackend.dispose = vi.fn(async () => {
      order.push("dispose");
    }) as never;

    const deps = makeLifecycleDeps(active, {
      broadcast: vi.fn(() => {
        order.push("broadcast");
      }),
    });
    const coordinator = new SessionLifecycleCoordinator(deps);

    await coordinator.handleSessionEnd("key", "agent_end");

    expect(active.sdkBackend.dispose).toHaveBeenCalledTimes(1);
    expect(active.session.status).toBe("stopped");
    expect(deps.persistSessionNow).toHaveBeenCalledWith("key", active.session);
    expect(deps.removeActiveSession).toHaveBeenCalledWith("key");
    expect(deps.releaseSession).toHaveBeenCalledWith({
      workspaceId: "ws-1",
      sessionId: "session-1",
    });
    expect(order).toEqual(["dispose", "broadcast"]);
  });
});

describe("SessionLifecycleCoordinator.resetIdleTimer", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("stops idle sessions after the configured timeout", () => {
    const active = makeLifecycleActiveSession();
    const deps = makeLifecycleDeps(active);
    const coordinator = new SessionLifecycleCoordinator(deps);

    coordinator.resetIdleTimer("key");

    vi.advanceTimersByTime(299_999);
    expect(deps.stopSession).not.toHaveBeenCalled();

    vi.advanceTimersByTime(1);
    expect(deps.stopSession).toHaveBeenCalledWith("session-1");
  });

  it("clears previous timer on reset", () => {
    const active = makeLifecycleActiveSession();
    const deps = makeLifecycleDeps(active);
    const coordinator = new SessionLifecycleCoordinator(deps);

    coordinator.resetIdleTimer("key");
    vi.advanceTimersByTime(200_000);
    coordinator.resetIdleTimer("key");

    vi.advanceTimersByTime(200_000);
    expect(deps.stopSession).not.toHaveBeenCalled();

    vi.advanceTimersByTime(100_000);
    expect(deps.stopSession).toHaveBeenCalledWith("session-1");
  });
});
