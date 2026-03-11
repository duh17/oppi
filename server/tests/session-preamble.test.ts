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
  dataDir: "/tmp/oppi-session-preamble-tests",
  defaultModel: "anthropic/claude-sonnet-4-0",
  sessionTimeout: 600_000,
  sessionIdleTimeoutMs: 600_000,
  workspaceIdleTimeoutMs: 1_800_000,
  maxSessionsPerWorkspace: 3,
  maxSessionsGlobal: 5,
};

function makeHarness(sessionOverrides: Partial<Session> = {}) {
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
  (manager as unknown as { resetIdleTimer: (key: string) => void }).resetIdleTimer = () => {};

  const { sdkBackend } = makeSdkBackendStub();
  const now = Date.now();
  const session: Session = {
    id: "s1",
    workspaceId: "w1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
    ...sessionOverrides,
  };

  const active = {
    session,
    sdkBackend,
    workspaceId: session.workspaceId ?? "w1",
    subscribers: new Set<(msg: ServerMessage) => void>(),
    pendingUIRequests: new Map(),
    partialResults: new Map(),
    streamedAssistantText: "",
    hasStreamedThinking: false,
    toolNames: new Map(),
    shellPreviewLastSent: new Map(),
    streamingArgPreviews: new Set(),
    turnCache: new TurnDedupeCache(),
    pendingTurnStarts: [],
    seq: 0,
    eventRing: new EventRing(),
  };

  ((manager as unknown as { active: Map<string, unknown> }).active).set(session.id, active);
  return { manager, sdkBackend, session };
}

describe("SessionManager pending prompt preamble", () => {
  it("injects preamble only into the first outbound prompt", async () => {
    const { manager, sdkBackend, session } = makeHarness();

    manager.setPendingPromptPreamble(
      session.id,
      "Hidden context: you are in a specialized editing mode.",
    );

    await manager.sendPrompt(session.id, "Add search to the toolbar.");
    await manager.sendPrompt(session.id, "Also make it darker.");

    expect(sdkBackend.prompt).toHaveBeenCalledTimes(2);
    expect(sdkBackend.prompt).toHaveBeenNthCalledWith(
      1,
      expect.stringContaining("Hidden context: you are in a specialized editing mode."),
      expect.objectContaining({}),
    );
    expect(sdkBackend.prompt).toHaveBeenNthCalledWith(
      1,
      expect.stringContaining("User request:\nAdd search to the toolbar."),
      expect.objectContaining({}),
    );
    expect(sdkBackend.prompt).toHaveBeenNthCalledWith(
      2,
      "Also make it darker.",
      expect.objectContaining({}),
    );
  });
});
