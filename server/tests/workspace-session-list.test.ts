import type { IncomingMessage, ServerResponse } from "node:http";
import { PassThrough } from "node:stream";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { RouteContext, RouteHelpers } from "../src/routes/types.js";
import type { Session, Workspace, LocalSession } from "../src/types.js";
import type { WorkspaceStoppedTimeBucketSnapshot } from "../src/storage/session-dao.js";

const localSessionState = vi.hoisted(() => ({
  snapshot: {
    sessions: [] as LocalSession[],
    lastScannedAt: 0,
  },
}));

vi.mock("../src/local-sessions.js", () => ({
  collectKnownLocalSessionIdentities: vi.fn(() => ({ files: new Set(), piSessionIds: new Set() })),
  discoverLocalSessions: vi.fn(async () => localSessionState.snapshot),
  invalidateLocalSessionsCache: vi.fn(),
  listCatalogedLocalSessions: vi.fn(() => localSessionState.snapshot),
  validateLocalSessionPath: vi.fn(),
  isControlSessionLocalArtifact: vi.fn(() => false),
  validateCwdAlignment: vi.fn(() => true),
}));

import { createSessionRoutes } from "../src/routes/sessions.js";

function makeWorkspace(overrides: Partial<Workspace> = {}): Workspace {
  return {
    id: "ws-1",
    name: "Oppi",
    createdAt: Date.now(),
    updatedAt: Date.now(),
    ...overrides,
  } as Workspace;
}

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "sess-1",
    workspaceId: "ws-1",
    status: "stopped",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeLocalSession(overrides: Partial<LocalSession> = {}): LocalSession {
  return {
    path: "/tmp/local.jsonl",
    piSessionId: "pi-1",
    cwd: "/Users/example/workspace/oppi",
    messageCount: 0,
    createdAt: Date.now(),
    lastModified: Date.now(),
    ...overrides,
  };
}

interface MockRouteContext {
  ctx: RouteContext;
  helpers: RouteHelpers;
  responses: Array<{ data: unknown; status: number }>;
  errors: Array<{ status: number; message: string }>;
  storage: {
    getWorkspace: ReturnType<typeof vi.fn>;
    listWorkspaces: ReturnType<typeof vi.fn>;
    listAllWorkspaceSessionSnapshots: ReturnType<typeof vi.fn>;
    listRecentWorkspaceSessionSnapshots: ReturnType<typeof vi.fn>;
    listWorkspaceTimeRangeSessionSnapshots: ReturnType<typeof vi.fn>;
    listStoppedWorkspaceTimeRangeSessionSnapshots: ReturnType<typeof vi.fn>;
    listWorkspaceStoppedTimeBuckets: ReturnType<typeof vi.fn>;
    listSessions: ReturnType<typeof vi.fn>;
    getDataDir: ReturnType<typeof vi.fn>;
  };
  sessions: {
    getActiveSessionIds: ReturnType<typeof vi.fn>;
    getActiveSession: ReturnType<typeof vi.fn>;
    getPendingUIRequestMessages: ReturnType<typeof vi.fn>;
  };
  sessionRuntimes: {
    getActiveSessionIds: ReturnType<typeof vi.fn>;
    getActiveSession: ReturnType<typeof vi.fn>;
    getPendingUIRequestMessages: ReturnType<typeof vi.fn>;
  };
  gate: {
    getPendingForUser: ReturnType<typeof vi.fn>;
  };
}

function createMockContext(workspace: Workspace = makeWorkspace()): MockRouteContext {
  const responses: Array<{ data: unknown; status: number }> = [];
  const errors: Array<{ status: number; message: string }> = [];

  const storage = {
    getWorkspace: vi.fn().mockReturnValue(workspace),
    listWorkspaces: vi.fn().mockReturnValue([workspace]),
    listAllWorkspaceSessionSnapshots: vi.fn<(workspaceId: string) => Session[]>(),
    listRecentWorkspaceSessionSnapshots:
      vi.fn<(workspaceId: string, recentDays: number, nowMs?: number) => Session[]>(),
    listWorkspaceTimeRangeSessionSnapshots:
      vi.fn<(workspaceId: string, sinceMs: number, untilMs: number) => Session[]>(),
    listStoppedWorkspaceTimeRangeSessionSnapshots:
      vi.fn<(workspaceId: string, sinceMs: number, untilMs: number) => Session[]>(),
    listWorkspaceStoppedTimeBuckets:
      vi.fn<
        (
          workspaceId: string,
          beforeMs: number,
          nowMs?: number,
        ) => WorkspaceStoppedTimeBucketSnapshot[]
      >(),
    listSessions: vi.fn().mockReturnValue([]),
    getDataDir: vi.fn().mockReturnValue("/tmp/oppi-workspace-session-list-tests"),
  };

  const sessions = {
    getActiveSessionIds: vi.fn().mockReturnValue([]),
    getActiveSession: vi.fn(),
    getPendingUIRequestMessages: vi.fn().mockReturnValue([]),
  };

  const gate = {
    getPendingForUser: vi.fn().mockReturnValue([]),
  };

  const ctx = {
    storage,
    sessions,
    sessionRuntimes: sessions,
    gate,
    skillRegistry: {},
    userSkillStore: {},
    providerAuth: {},
    ensureSessionContextWindow: (session: Session) => session,
    resolveWorkspaceForSession: () => workspace,
    refreshModelCatalog: vi.fn().mockResolvedValue(undefined),
    getModelCatalog: vi.fn().mockReturnValue([]),
    serverStartedAt: Date.now(),
    serverVersion: "test",
    piVersion: "test",
  } as unknown as RouteContext;

  const helpers: RouteHelpers = {
    parseBody: async <T>(_req: IncomingMessage): Promise<T> => ({}) as T,
    json: (_res: ServerResponse, data: unknown, status?: number) => {
      responses.push({ data, status: status ?? 200 });
    },
    compressedJson: (
      _req: IncomingMessage,
      _res: ServerResponse,
      data: unknown,
      status?: number,
    ) => {
      responses.push({ data, status: status ?? 200 });
    },
    error: (_res: ServerResponse, status: number, message: string) => {
      errors.push({ status, message });
    },
  };

  return { ctx, helpers, responses, errors, storage, sessions, sessionRuntimes: sessions, gate };
}

async function dispatch(mock: MockRouteContext, path: string, url: string): Promise<boolean> {
  const dispatcher = createSessionRoutes(mock.ctx, mock.helpers);
  const requestUrl = new URL(url);
  const req = new PassThrough() as unknown as IncomingMessage;
  req.url = `${requestUrl.pathname}${requestUrl.search}`;
  return dispatcher({
    method: "GET",
    path,
    url: requestUrl,
    req,
    res: {} as ServerResponse,
  });
}

describe("workspace session list routes", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-05-13T12:00:00Z"));
    localSessionState.snapshot = { sessions: [], lastScannedAt: Date.now() };
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("requires explicit status for workspace session collections", async () => {
    const mock = createMockContext();

    const handled = await dispatch(
      mock,
      "/workspaces/ws-1/sessions",
      "https://localhost/workspaces/ws-1/sessions?recentDays=3",
    );

    expect(handled).toBe(true);
    expect(mock.responses).toHaveLength(0);
    expect(mock.errors).toEqual([{ status: 400, message: "status is required" }]);
  });

  it("rejects unknown workspace session collection status values", async () => {
    const mock = createMockContext();

    const handled = await dispatch(
      mock,
      "/workspaces/ws-1/sessions",
      "https://localhost/workspaces/ws-1/sessions?status=all",
    );

    expect(handled).toBe(true);
    expect(mock.responses).toHaveLength(0);
    expect(mock.errors).toEqual([
      { status: 400, message: "status must include only 'active' and/or 'stopped'" },
    ]);
  });

  it("requires a time range when workspace session status includes stopped", async () => {
    const mock = createMockContext();

    const handled = await dispatch(
      mock,
      "/workspaces/ws-1/sessions",
      "https://localhost/workspaces/ws-1/sessions?status=active,stopped",
    );

    expect(handled).toBe(true);
    expect(mock.responses).toHaveLength(0);
    expect(mock.errors).toEqual([
      { status: 400, message: "sinceMs and untilMs are required when status includes stopped" },
    ]);
  });

  it("accepts list-style date bounds and includes the whole local until day", async () => {
    const mock = createMockContext(makeWorkspace({ hostMount: "/tmp" }));
    const sinceMs = new Date(2026, 6, 1, 0, 0, 0, 0).getTime();
    const untilExclusiveMs = new Date(2026, 6, 3, 0, 0, 0, 0).getTime();

    mock.storage.listAllWorkspaceSessionSnapshots.mockReturnValue([
      makeSession({ id: "active-inside", status: "busy", lastActivity: sinceMs + 1_000 }),
      makeSession({ id: "active-after", status: "busy", lastActivity: untilExclusiveMs }),
    ]);
    mock.storage.listStoppedWorkspaceTimeRangeSessionSnapshots.mockReturnValue([
      makeSession({
        id: "stopped-end-of-day",
        status: "stopped",
        lastActivity: untilExclusiveMs - 1,
      }),
    ]);

    await dispatch(
      mock,
      "/workspaces/ws-1/sessions",
      "https://localhost/workspaces/ws-1/sessions?status=active,stopped&since=2026-07-01&until=2026-07-02",
    );

    expect(mock.errors).toEqual([]);
    expect(mock.storage.listStoppedWorkspaceTimeRangeSessionSnapshots).toHaveBeenCalledWith(
      "ws-1",
      sinceMs,
      untilExclusiveMs,
      "main",
    );
    const response = mock.responses[0]?.data as {
      active: Array<{ id: string }>;
      stopped: Array<{ id: string }>;
    };
    expect(response.active.map((row) => row.id)).toEqual(["active-inside"]);
    expect(response.stopped.map((row) => row.id)).toEqual(["stopped-end-of-day"]);
  });

  it("returns sectioned active and stopped workspace session rows", async () => {
    const mock = createMockContext(makeWorkspace({ hostMount: "/tmp" }));
    const sinceMs = Date.parse("2026-05-13T00:00:00Z");
    const untilMs = Date.parse("2026-05-14T00:00:00Z");

    mock.storage.listAllWorkspaceSessionSnapshots.mockReturnValue([
      makeSession({
        id: "old-ready",
        status: "ready",
        lastActivity: sinceMs - 86_400_000,
      }),
      makeSession({
        id: "stored-stopped-old",
        status: "stopped",
        lastActivity: sinceMs - 1_000,
      }),
    ]);
    mock.sessions.getActiveSessionIds.mockReturnValue(["live-busy"]);
    mock.sessions.getActiveSession.mockImplementation((sessionId: string) =>
      sessionId === "live-busy"
        ? makeSession({ id: "live-busy", status: "busy", lastActivity: sinceMs + 5_000 })
        : undefined,
    );
    mock.storage.listStoppedWorkspaceTimeRangeSessionSnapshots.mockReturnValue([
      makeSession({ id: "stopped-today", status: "stopped", lastActivity: sinceMs + 10_000 }),
      makeSession({ id: "active-leak", status: "busy", lastActivity: sinceMs + 20_000 }),
      makeSession({ id: "stopped-outside", status: "stopped", lastActivity: untilMs + 1_000 }),
    ]);
    localSessionState.snapshot = {
      lastScannedAt: Date.now(),
      sessions: [
        makeLocalSession({
          path: "/tmp/tui-today.jsonl",
          piSessionId: "tui-today",
          lastModified: sinceMs + 15_000,
        }),
        makeLocalSession({
          path: "/tmp/tui-old.jsonl",
          piSessionId: "tui-old",
          lastModified: sinceMs - 10_000,
        }),
      ],
    };

    const handled = await dispatch(
      mock,
      "/workspaces/ws-1/sessions",
      `https://localhost/workspaces/ws-1/sessions?status=active,stopped&sinceMs=${sinceMs}&untilMs=${untilMs}`,
    );

    expect(handled).toBe(true);
    expect(mock.errors).toHaveLength(0);

    const response = mock.responses[0]?.data as {
      workspaceId: string;
      sinceMs: number;
      untilMs: number;
      active: Array<Record<string, unknown>>;
      stopped: Array<Record<string, unknown>>;
    };

    expect(response.workspaceId).toBe("ws-1");
    expect(response.sinceMs).toBe(sinceMs);
    expect(response.untilMs).toBe(untilMs);
    expect(response.active.map((session) => session.id)).toEqual(["live-busy", "old-ready"]);
    expect(response.stopped.map((session) => session.id)).toEqual([
      "/tmp/tui-today.jsonl",
      "stopped-today",
    ]);
    expect(response.stopped[0]).toMatchObject({
      source: "tui",
      piSessionId: "tui-today",
      path: "/tmp/tui-today.jsonl",
      status: "stopped",
    });
    expect(response.stopped.map((session) => session.id)).not.toContain("active-leak");
    expect(response.stopped.map((session) => session.id)).not.toContain("stopped-outside");
  });

  it("returns stopped session bucket summaries from the bucket resource", async () => {
    const mock = createMockContext(makeWorkspace({ hostMount: "/tmp" }));
    const beforeMs = Date.parse("2026-05-13T00:00:00Z");

    mock.storage.listWorkspaceStoppedTimeBuckets.mockReturnValue([
      {
        bucketId: "day:2026-05-12",
        bucketKind: "day",
        startMs: Date.parse("2026-05-12T00:00:00Z"),
        endMs: Date.parse("2026-05-13T00:00:00Z"),
        itemCount: 1,
        latestActivity: Date.parse("2026-05-12T18:00:00Z"),
      },
    ]);
    localSessionState.snapshot = {
      lastScannedAt: Date.now(),
      sessions: [
        makeLocalSession({
          path: "/tmp/tui-old.jsonl",
          piSessionId: "tui-old",
          lastModified: Date.parse("2026-05-12T19:00:00Z"),
        }),
        makeLocalSession({
          path: "/tmp/tui-visible.jsonl",
          piSessionId: "tui-visible",
          lastModified: beforeMs + 1_000,
        }),
      ],
    };

    const handled = await dispatch(
      mock,
      "/workspaces/ws-1/session-buckets",
      `https://localhost/workspaces/ws-1/session-buckets?status=stopped&beforeMs=${beforeMs}`,
    );

    expect(handled).toBe(true);
    expect(mock.errors).toHaveLength(0);
    expect(mock.storage.listWorkspaceStoppedTimeBuckets).toHaveBeenCalledWith(
      "ws-1",
      beforeMs,
      Date.now(),
      "main",
    );

    const response = mock.responses[0]?.data as {
      workspaceId: string;
      status: string;
      beforeMs: number;
      buckets: Array<{
        bucketId: string;
        itemCount: number;
        managedStoppedCount: number;
        importableLocalCount: number;
      }>;
    };

    expect(response.workspaceId).toBe("ws-1");
    expect(response.status).toBe("stopped");
    expect(response.beforeMs).toBe(beforeMs);
    expect(response.buckets).toEqual([
      expect.objectContaining({
        bucketId: "day:2026-05-12",
        itemCount: 2,
        managedStoppedCount: 1,
        importableLocalCount: 1,
      }),
    ]);
  });

  it("filters the global recent path by explicit activity bounds instead of recentDays", async () => {
    const mock = createMockContext();
    const sinceMs = 1_000;
    const untilMs = 2_000;
    mock.storage.listWorkspaceTimeRangeSessionSnapshots.mockReturnValue([
      makeSession({ id: "newer-outside", status: "ready", lastActivity: untilMs + 1 }),
      makeSession({ id: "inside", status: "ready", lastActivity: untilMs }),
      makeSession({ id: "older-outside", status: "stopped", lastActivity: sinceMs - 1 }),
    ]);

    await dispatch(
      mock,
      "/sessions/recent",
      `https://localhost/sessions/recent?since=${sinceMs}&until=${untilMs}`,
    );

    expect(mock.errors).toEqual([]);
    expect(mock.storage.listWorkspaceTimeRangeSessionSnapshots).toHaveBeenCalledWith(
      "ws-1",
      sinceMs,
      untilMs + 1,
    );
    expect(mock.storage.listAllWorkspaceSessionSnapshots).not.toHaveBeenCalled();
    expect(mock.storage.listRecentWorkspaceSessionSnapshots).not.toHaveBeenCalled();
    const response = mock.responses[0]?.data as { sessions: Array<{ id: string }> };
    expect(response.sessions.map((row) => row.id)).toEqual(["inside"]);
  });

  it("returns aggregated recent workspace session summaries as thin summaries", async () => {
    const workspaceTwo = makeWorkspace({ id: "ws-2", name: "Other" });
    const mock = createMockContext();
    const now = Date.parse("2026-05-13T12:00:00Z");
    mock.storage.listWorkspaces.mockReturnValue([makeWorkspace(), workspaceTwo]);
    mock.storage.listRecentWorkspaceSessionSnapshots.mockImplementation((workspaceId: string) => {
      if (workspaceId === "ws-1") {
        return [
          makeSession({
            id: "ws-1-row",
            workspaceId: "ws-1",
            status: "ready",
            lastActivity: now,
            piSessionFile: "/Users/example/.pi/agent/sessions/ws-1-row.jsonl",
            warnings: ["local warning"],
          }),
        ];
      }
      return [
        makeSession({
          id: "ws-2-row",
          workspaceId: "ws-2",
          status: "busy",
          lastActivity: now + 1_000,
          piSessionFile: "/Users/example/.pi/agent/sessions/ws-2-row.jsonl",
          warnings: ["other warning"],
        }),
      ];
    });
    mock.gate.getPendingForUser.mockReturnValue([{ sessionId: "ws-1-row", workspaceId: "ws-1" }]);
    mock.sessions.getActiveSessionIds.mockReturnValue(["ws-2-row"]);
    mock.sessions.getPendingUIRequestMessages.mockImplementation((sessionId: string) =>
      sessionId === "ws-2-row"
        ? [
            {
              type: "extension_ui_request",
              id: "ask-1",
              sessionId,
              method: "ask",
              questions: [
                { id: "q1", question: "Pick one", options: [{ value: "yes", label: "Yes" }] },
              ],
            },
            {
              type: "extension_ui_request",
              id: "select-1",
              sessionId,
              method: "select",
              title: "Dangerous command",
              options: ["Allow once", "Deny"],
            },
          ]
        : [],
    );

    const handled = await dispatch(
      mock,
      "/sessions/recent",
      "https://localhost/sessions/recent?recentDays=3",
    );

    expect(handled).toBe(true);
    expect(mock.errors).toHaveLength(0);

    const response = mock.responses[0]?.data as {
      sessions: Array<Record<string, unknown>>;
    };

    expect(mock.storage.listRecentWorkspaceSessionSnapshots).toHaveBeenCalledTimes(2);
    expect(response.sessions.map((session) => session.id)).toEqual(["ws-2-row", "ws-1-row"]);
    expect(response.sessions[0]).toMatchObject({
      id: "ws-2-row",
      pendingAskCount: 2,
    });
    expect(response.sessions[1]).toMatchObject({
      id: "ws-1-row",
      pendingAskCount: 0,
    });
    expect(response.sessions[0]).not.toHaveProperty("pendingPermissionCount");
    expect(response.sessions[1]).not.toHaveProperty("pendingPermissionCount");
    expect(response.sessions[0]).not.toHaveProperty("piSessionFile");
    expect(response.sessions[0]).not.toHaveProperty("warnings");
    expect(response.sessions[1]).not.toHaveProperty("piSessionFile");
    expect(response.sessions[1]).not.toHaveProperty("warnings");
  });

  it("includes only explicitly declared control sessions in the global recent list", async () => {
    const mock = createMockContext();
    const now = Date.parse("2026-05-13T12:00:00Z");
    mock.storage.listAllWorkspaceSessionSnapshots.mockReturnValue([
      makeSession({ id: "workspace-row", lastActivity: now - 1_000 }),
    ]);
    mock.storage.listSessions.mockReturnValue([
      makeSession({ id: "workspace-row", lastActivity: now - 1_000 }),
      makeSession({
        id: "control-row",
        workspaceId: undefined,
        lastActivity: now,
        control: { domain: "schedules", intent: "create" },
      }),
      makeSession({
        id: "undeclared-workspace-less",
        workspaceId: undefined,
        lastActivity: now + 1_000,
      }),
    ]);

    await dispatch(mock, "/sessions/recent", "https://localhost/sessions/recent");

    const response = mock.responses[0]?.data as { sessions: Array<Session> };
    expect(response.sessions.map((session) => session.id)).toEqual([
      "control-row",
      "workspace-row",
    ]);
    expect(response.sessions[0]?.control).toEqual({ domain: "schedules", intent: "create" });
  });

  it("does not leak active control sessions into workspace session collections", async () => {
    const mock = createMockContext();
    const control = makeSession({
      id: "control-row",
      workspaceId: undefined,
      status: "busy",
      control: { domain: "agents", intent: "create" },
    });
    mock.sessions.getActiveSessionIds.mockReturnValue([control.id]);
    mock.sessions.getActiveSession.mockReturnValue(control);
    mock.storage.listAllWorkspaceSessionSnapshots.mockReturnValue([]);

    await dispatch(
      mock,
      "/workspaces/ws-1/sessions",
      "https://localhost/workspaces/ws-1/sessions?status=active",
    );

    const response = mock.responses[0]?.data as { active: Session[] };
    expect(response.active).toEqual([]);
  });

  it("counts pending mirror extension dialogs as workspace row attention", async () => {
    const mock = createMockContext();
    const now = Date.parse("2026-05-13T12:00:00Z");
    const mirrorSession = makeSession({
      id: "mirror-row",
      status: "busy",
      runtime: "pi-tui",
      lastActivity: now,
    });
    mock.storage.listAllWorkspaceSessionSnapshots.mockReturnValue([mirrorSession]);
    mock.ctx.sessionRuntimes = {
      getActiveSessionIds: () => new Set(["mirror-row"]),
      getActiveSession: (sessionId: string) =>
        sessionId === "mirror-row" ? mirrorSession : undefined,
      getPendingUIRequestMessages: (sessionId: string) =>
        sessionId === "mirror-row"
          ? [
              {
                type: "extension_ui_request",
                id: "mirror-select-1",
                sessionId,
                method: "select",
                title: "Dangerous command",
                options: ["Allow once", "Deny"],
              },
            ]
          : [],
    } as unknown as RouteContext["sessionRuntimes"];

    const handled = await dispatch(
      mock,
      "/workspaces/ws-1/sessions",
      "https://localhost/workspaces/ws-1/sessions?status=active",
    );

    expect(handled).toBe(true);
    expect(mock.errors).toHaveLength(0);

    const response = mock.responses[0]?.data as {
      active: Array<Record<string, unknown>>;
    };

    expect(response.active).toHaveLength(1);
    expect(response.active[0]).toMatchObject({
      id: "mirror-row",
      pendingAskCount: 1,
    });
    expect(response.active[0]).not.toHaveProperty("pendingPermissionCount");
  });

  it("filters generic and Agent rows by activity before applying limit", async () => {
    const mock = createMockContext();
    mock.storage.listSessions.mockReturnValue([
      makeSession({
        id: "outside-new",
        lastActivity: 4_000,
        launch: { agentId: "agent-1", agentVersion: 1 },
      }),
      makeSession({
        id: "inside-new",
        lastActivity: 2_500,
        launch: { agentId: "agent-1", agentVersion: 1 },
      }),
      makeSession({
        id: "inside-old",
        lastActivity: 2_000,
        launch: { agentId: "agent-1", agentVersion: 1 },
      }),
    ]);

    await dispatch(
      mock,
      "/sessions",
      "https://localhost/sessions?agentId=agent-1&since=1500&until=3000&limit=1",
    );

    expect(mock.errors).toEqual([]);
    const response = mock.responses[0]?.data as { sessions: Array<{ id: string }> };
    expect(response.sessions.map((row) => row.id)).toEqual(["inside-new"]);
  });

  it.each([
    ["/sessions", "/sessions", "since=not-a-date"],
    ["/sessions/recent", "/sessions/recent", "since=not-a-date"],
    ["/workspaces/ws-1/sessions", "/workspaces/ws-1/sessions", "status=active&since=not-a-date"],
  ])("rejects invalid list bounds on %s", async (path, pathname, query) => {
    const mock = createMockContext();
    await dispatch(mock, path, `https://localhost${pathname}?${query}`);
    expect(mock.errors).toEqual([
      { status: 400, message: "invalid session list timestamp: not-a-date" },
    ]);
  });

  it("rejects reversed generic list bounds", async () => {
    const mock = createMockContext();
    await dispatch(mock, "/sessions", "https://localhost/sessions?since=3000&until=2000");
    expect(mock.errors).toEqual([
      { status: 400, message: "session list since must be before or equal to until" },
    ]);
  });

  it("returns only the requested stopped bucket contents", async () => {
    const mock = createMockContext(makeWorkspace({ hostMount: "/tmp" }));
    const sinceMs = Date.parse("2026-05-10T00:00:00Z");
    const untilMs = Date.parse("2026-05-11T00:00:00Z");

    mock.storage.listWorkspaceTimeRangeSessionSnapshots.mockReturnValue([
      makeSession({ id: "active-leak", status: "busy", lastActivity: Date.now() }),
    ]);
    mock.sessions.getActiveSessionIds.mockReturnValue(["live-active"]);
    mock.sessions.getActiveSession.mockReturnValue(
      makeSession({ id: "live-active", status: "busy", lastActivity: Date.now() }),
    );
    mock.storage.listStoppedWorkspaceTimeRangeSessionSnapshots.mockReturnValue([
      makeSession({ id: "stopped-in-bucket", status: "stopped", lastActivity: sinceMs + 1_000 }),
    ]);
    mock.storage.listWorkspaceStoppedTimeBuckets.mockReturnValue([]);
    localSessionState.snapshot = {
      lastScannedAt: Date.now(),
      sessions: [
        makeLocalSession({
          path: "/tmp/in-bucket.jsonl",
          piSessionId: "local-in-bucket",
          lastModified: sinceMs + 5_000,
        }),
        makeLocalSession({
          path: "/tmp/out-of-bucket.jsonl",
          piSessionId: "local-out-of-bucket",
          lastModified: untilMs + 5_000,
        }),
      ],
    };

    const handled = await dispatch(
      mock,
      "/workspaces/ws-1/sessions",
      `https://localhost/workspaces/ws-1/sessions?status=stopped&sinceMs=${sinceMs}&untilMs=${untilMs}`,
    );

    expect(handled).toBe(true);
    expect(mock.errors).toHaveLength(0);
    expect(mock.storage.listStoppedWorkspaceTimeRangeSessionSnapshots).toHaveBeenCalledWith(
      "ws-1",
      sinceMs,
      untilMs,
      "main",
    );
    expect(mock.storage.listWorkspaceTimeRangeSessionSnapshots).not.toHaveBeenCalled();

    const response = mock.responses[0]?.data as {
      workspaceId: string;
      sinceMs: number;
      untilMs: number;
      stopped: Array<Record<string, unknown>>;
    };

    expect(response.workspaceId).toBe("ws-1");
    expect(response.sinceMs).toBe(sinceMs);
    expect(response.untilMs).toBe(untilMs);
    expect(response.stopped.map((session) => session.id)).toEqual([
      "/tmp/in-bucket.jsonl",
      "stopped-in-bucket",
    ]);
    expect(response.stopped[0]).toMatchObject({
      source: "tui",
      piSessionId: "local-in-bucket",
    });
  });
});
