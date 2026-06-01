import { describe, expect, it, vi } from "vitest";
import { SessionManager } from "../src/sessions.js";
import type { Storage } from "../src/storage.js";
import type { ServerConfig, Session, Workspace } from "../src/types.js";

const TEST_CONFIG: ServerConfig = {
  port: 7749,
  host: "127.0.0.1",
  dataDir: "/tmp/oppi-spawn-state-tests",
  defaultModel: "anthropic/claude-sonnet-4-0",
  sessionIdleTimeoutMs: 600_000,
  workspaceIdleTimeoutMs: 1_800_000,
  maxSessionsPerWorkspace: 10,
  maxSessionsGlobal: 20,
};

function makeSession(id: string, overrides: Partial<Session> = {}): Session {
  const now = Date.now();
  return {
    id,
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

function makeWorkspace(id: string): Workspace {
  return {
    id,
    name: "Workspace",
    createdAt: Date.now(),
    status: "ready",
    defaultModel: "anthropic/claude-sonnet-4-0",
    hostMount: "~/workspace/oppi",
  };
}

function makeStorageHarness(): Storage & {
  _sessions: Map<string, Session>;
  _workspaces: Map<string, Workspace>;
} {
  const sessions = new Map<string, Session>();
  const workspaces = new Map<string, Workspace>();
  let childId = 0;

  return {
    _sessions: sessions,
    _workspaces: workspaces,
    getConfig: () => TEST_CONFIG,
    getWorkspace: (id: string) => {
      const ws = workspaces.get(id);
      return ws ? { ...ws } : undefined;
    },
    getSession: (id: string) => {
      const session = sessions.get(id);
      return session ? { ...session } : undefined;
    },
    saveSession: (session: Session) => {
      sessions.set(session.id, { ...session });
    },
    createSession: (name?: string, model?: string) => {
      childId += 1;
      const session = makeSession(`child-${childId}`, {
        name,
        model,
        status: "starting",
      });
      sessions.set(session.id, { ...session });
      return session;
    },
    listSessions: () => [...sessions.values()],
    deleteSession: vi.fn(() => true),
    listWorkspaces: () => [...workspaces.values()],
    saveWorkspace: vi.fn(),
    deleteWorkspace: vi.fn(),
    createWorkspace: vi.fn(),
    saveConfig: vi.fn(),
    getDataDir: vi.fn(() => "/tmp/oppi-session-spawn-state-tests"),
    getSessionsDir: vi.fn(() => "/tmp"),
    getWorkspacesDir: vi.fn(() => "/tmp"),
  } as unknown as Storage & {
    _sessions: Map<string, Session>;
    _workspaces: Map<string, Workspace>;
  };
}

function makeManagerHarness() {
  const storage = makeStorageHarness();
  const manager = new SessionManager(storage);
  (manager as { resetIdleTimer: (key: string) => void }).resetIdleTimer = () => {};

  return { manager, storage };
}

describe("SessionManager spawn flow state persistence", () => {
  it("spawnChildSession keeps state updates written by startSession", async () => {
    const { manager, storage } = makeManagerHarness();
    const workspace = makeWorkspace("w1");
    storage._workspaces.set(workspace.id, workspace);
    storage.saveSession(
      makeSession("parent-1", {
        workspaceId: workspace.id,
        workspaceName: workspace.name,
        model: "anthropic/claude-sonnet-4-5",
      }),
    );

    vi.spyOn(manager, "startSession").mockImplementation(async (sessionId: string) => {
      const started = storage.getSession(sessionId);
      if (!started) throw new Error("expected child session");
      started.status = "ready";
      storage.saveSession(started);
      return started;
    });
    vi.spyOn(manager, "sendPrompt").mockResolvedValue(undefined);

    const child = await manager.spawnChildSession("parent-1", {
      prompt: "hello child",
    });

    const persisted = storage.getSession(child.id);
    expect(persisted).toBeDefined();
    expect(persisted?.status).toBe("ready");
    expect(persisted?.firstMessage).toBe("hello child");
  });

  it("spawnDetachedSession keeps state updates written by startSession", async () => {
    const { manager, storage } = makeManagerHarness();
    const workspace = makeWorkspace("w2");
    storage._workspaces.set(workspace.id, workspace);
    storage.saveSession(
      makeSession("origin-1", {
        workspaceId: workspace.id,
        workspaceName: workspace.name,
      }),
    );

    vi.spyOn(manager, "startSession").mockImplementation(async (sessionId: string) => {
      const started = storage.getSession(sessionId);
      if (!started) throw new Error("expected detached session");
      started.status = "ready";
      storage.saveSession(started);
      return started;
    });
    vi.spyOn(manager, "sendPrompt").mockResolvedValue(undefined);

    const detached = await manager.spawnDetachedSession("origin-1", {
      prompt: "hello detached",
    });

    const persisted = storage.getSession(detached.id);
    expect(persisted).toBeDefined();
    expect(persisted?.status).toBe("ready");
    expect(persisted?.firstMessage).toBe("hello detached");
  });
});
