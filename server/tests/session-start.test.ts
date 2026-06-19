import { describe, expect, it, vi } from "vitest";

import { SdkBackend } from "../src/sdk-backend.js";
import { SessionStartCoordinator, type SessionStartCoordinatorDeps } from "../src/session-start.js";
import type { Storage } from "../src/storage.js";
import type { ServerConfig, Session, Workspace } from "../src/types.js";
import type { WorkspaceRuntime } from "../src/workspace-runtime.js";

const TEST_CONFIG: ServerConfig = {
  port: 7749,
  host: "127.0.0.1",
  dataDir: "/tmp/oppi-session-start-tests",
  sessionIdleTimeoutMs: 600_000,
  workspaceIdleTimeoutMs: 1_800_000,
  maxSessionsPerWorkspace: 10,
  maxSessionsGlobal: 20,
};

function makeSession(overrides: Partial<Session> = {}): Session {
  const now = Date.now();
  return {
    id: "s1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    model: "anthropic/claude-sonnet-4-0",
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeWorkspace(): Workspace {
  const now = Date.now();
  return {
    id: "w1",
    name: "Workspace",
    systemPromptMode: "append",
    createdAt: now,
    updatedAt: now,
    hostMount: "/tmp/workspace",
  };
}

function makeDeps(session: Session): SessionStartCoordinatorDeps & {
  persistedStatuses: Session["status"][];
} {
  const persistedStatuses: Session["status"][] = [];
  const storage = {
    getSession: vi.fn(() => session),
    listSessions: vi.fn(() => [session]),
    getDataDir: vi.fn(() => TEST_CONFIG.dataDir),
  } as unknown as Storage;

  const runtimeManager = {
    withWorkspaceLock: vi.fn(async (_workspaceId: string, fn: () => Promise<Session>) => fn()),
    reserveSessionStart: vi.fn(),
    markSessionReady: vi.fn(),
    releaseSession: vi.fn(),
    getLimits: vi.fn(() => ({
      maxSessionsPerWorkspace: 20,
      maxSessionsGlobal: 40,
      sessionIdleTimeoutMs: 600_000,
      workspaceIdleTimeoutMs: 1_800_000,
    })),
  } as unknown as WorkspaceRuntime;

  const deps: SessionStartCoordinatorDeps & { persistedStatuses: Session["status"][] } = {
    storage,
    runtimeManager,
    config: TEST_CONFIG,
    eventRingCapacity: 20,
    getSkillPathResolver: vi.fn(() => null),
    onPiEvent: vi.fn(),
    onSessionEnd: vi.fn(),
    registerActiveSession: vi.fn(),
    persistSessionNow: vi.fn((_key, s) => {
      persistedStatuses.push(s.status);
    }),
    resetIdleTimer: vi.fn(),
    bootstrapSessionState: vi.fn(async () => {}),
    persistedStatuses,
  };

  return deps;
}

describe("SessionStartCoordinator status persistence", () => {
  it("persists starting during SDK startup, then ready after registration", async () => {
    const session = makeSession({ status: "ready" });
    const deps = makeDeps(session);
    const workspace = makeWorkspace();
    vi.spyOn(SdkBackend, "create").mockResolvedValue({} as SdkBackend);

    await new SessionStartCoordinator(deps).startSessionInner("key", session.id, workspace);

    expect(deps.persistedStatuses).toEqual(["starting", "ready"]);
    expect(deps.runtimeManager.reserveSessionStart).toHaveBeenCalledWith({
      workspaceId: workspace.id,
      sessionId: session.id,
    });
    expect(deps.runtimeManager.markSessionReady).toHaveBeenCalledWith({
      workspaceId: workspace.id,
      sessionId: session.id,
    });
  });

  it("rolls old starting sessions back to ready when SDK startup fails", async () => {
    const session = makeSession({ status: "starting" });
    const deps = makeDeps(session);
    vi.spyOn(SdkBackend, "create").mockRejectedValue(new Error("boom"));

    await expect(
      new SessionStartCoordinator(deps).startSessionInner("key", session.id),
    ).rejects.toThrow("boom");

    expect(deps.persistedStatuses).toEqual(["starting", "ready"]);
    expect(session.status).toBe("ready");
    expect(deps.runtimeManager.releaseSession).toHaveBeenCalledWith({
      workspaceId: `session-${session.id}`,
      sessionId: session.id,
    });
  });
});
