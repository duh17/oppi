import { describe, expect, it, vi } from "vitest";

import { DEFAULT_AGENT_ID } from "../src/default-agent.js";
import type { OppiExtensionSettingsSnapshot } from "../src/oppi-extension-settings.js";
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
    getOppiExtensionSettings: vi.fn(
      (): OppiExtensionSettingsSnapshot => ({
        enabled: false,
        approvalPolicy: "confirmDestructiveOnly",
        mobileOutputGuideEnabled: false,
        revision: 0,
      }),
    ),
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

  it("passes one atomic current-settings reader to managed backend construction", async () => {
    const session = makeSession({ status: "ready" });
    const deps = makeDeps(session);
    const latest: OppiExtensionSettingsSnapshot = {
      enabled: true,
      approvalPolicy: "readOnly",
      mobileOutputGuideEnabled: false,
      revision: 8,
    };
    const getOppiExtensionSettings = vi.fn(() => latest);
    Object.assign(deps.storage, { getOppiExtensionSettings });
    const createSpy = vi.spyOn(SdkBackend, "create").mockResolvedValue({} as SdkBackend);

    await new SessionStartCoordinator(deps).startSessionInner("key", session.id, makeWorkspace());

    const config = createSpy.mock.calls.at(-1)?.[0];
    expect(config?.getOppiExtensionSettings).toBeTypeOf("function");
    expect(config?.getOppiExtensionSettings?.()).toBe(latest);
    expect(getOppiExtensionSettings).toHaveBeenCalledOnce();
  });

  it("uses the saved Agent definition version recorded on the session", async () => {
    const session = makeSession({
      status: "ready",
      launch: {
        status: "accepted",
        source: "agent",
        agentId: "agent-1",
        agentVersion: 1,
        requestedAt: 1,
      },
    });
    const deps = makeDeps(session);
    const getAgentVersion = vi.fn(() => ({
      id: "agent-1",
      version: 1,
      definition: { name: "Reviewer v1", instructions: { mode: "append", text: "v1" } },
      createdAt: 1,
    }));
    const getAgent = vi.fn(() => ({
      definition: { name: "Reviewer v2", instructions: { mode: "append", text: "v2" } },
    }));
    Object.assign(deps.storage, {
      getAgentDefinitionStore: () => ({ getAgentVersion, getAgent }),
    });
    const createSpy = vi.spyOn(SdkBackend, "create").mockResolvedValue({} as SdkBackend);

    await new SessionStartCoordinator(deps).startSessionInner("key", session.id, makeWorkspace());

    expect(getAgentVersion).toHaveBeenCalledWith("agent-1", 1);
    expect(getAgent).not.toHaveBeenCalled();
    expect(createSpy).toHaveBeenCalledWith(
      expect.objectContaining({
        agentDefinition: expect.objectContaining({ name: "Reviewer v1" }),
      }),
    );
  });

  it("applies Oppi agent safety defaults to recorded Agent versions", async () => {
    const session = makeSession({
      status: "ready",
      launch: {
        status: "accepted",
        source: "agent",
        agentId: DEFAULT_AGENT_ID,
        agentVersion: 2,
        requestedAt: 1,
      },
    });
    const deps = makeDeps(session);
    const getAgentVersion = vi.fn(() => ({
      id: DEFAULT_AGENT_ID,
      version: 2,
      definition: {
        name: "oppi-default-agent",
        resources: { noContextFiles: true, extensionIds: ["oppi"] },
        sessionDefaults: { excludeTools: ["write", "bash"] },
      },
      createdAt: 1,
    }));
    const getAgent = vi.fn();
    Object.assign(deps.storage, {
      getAgentDefinitionStore: () => ({ getAgentVersion, getAgent }),
    });
    const createSpy = vi.spyOn(SdkBackend, "create").mockResolvedValue({} as SdkBackend);

    await new SessionStartCoordinator(deps).startSessionInner("key", session.id, makeWorkspace());

    expect(createSpy).toHaveBeenCalledWith(
      expect.objectContaining({
        agentDefinition: expect.objectContaining({
          resources: { noContextFiles: true },
          sessionDefaults: { noTools: "builtin", tools: ["oppi", "ask", "read", "edit"] },
        }),
      }),
    );
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
