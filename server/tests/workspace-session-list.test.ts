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
  discoverLocalSessions: vi.fn(async () => localSessionState.snapshot),
  invalidateLocalSessionsCache: vi.fn(),
  listCatalogedLocalSessions: vi.fn(() => localSessionState.snapshot),
  validateLocalSessionPath: vi.fn(),
  validateCwdAlignment: vi.fn(() => true),
}));

import { createSessionRoutes } from "../src/routes/sessions.js";

function makeWorkspace(overrides: Partial<Workspace> = {}): Workspace {
  return {
    id: "ws-1",
    name: "Oppi",
    skills: [],
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
    cwd: "/Users/chenda/workspace/oppi",
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
    getPendingAskMessage: ReturnType<typeof vi.fn>;
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
    getPendingAskMessage: vi.fn(),
  };

  const gate = {
    getPendingForUser: vi.fn().mockReturnValue([]),
  };

  const ctx = {
    storage,
    sessions,
    gate,
    skillRegistry: {},
    userSkillStore: {},
    userEventStore: { recordEvent: vi.fn() },
    providerAuth: {},
    ensureSessionContextWindow: (session: Session) => session,
    resolveWorkspaceForSession: () => workspace,
    refreshModelCatalog: vi.fn().mockResolvedValue(undefined),
    getModelCatalog: vi.fn().mockReturnValue([]),
    getRuntimeUpdateStatus: vi.fn().mockResolvedValue({ upToDate: true }),
    runRuntimeUpdate: vi.fn().mockResolvedValue({ success: true }),
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

  return { ctx, helpers, responses, errors, storage, sessions, gate };
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

  it("returns sectioned active and stopped workspace session rows", async () => {
    const mock = createMockContext(makeWorkspace({ hostMount: "~/workspace/oppi" }));
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
    const mock = createMockContext(makeWorkspace({ hostMount: "~/workspace/oppi" }));
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
            piSessionFile: "/Users/chenda/.pi/agent/sessions/ws-1-row.jsonl",
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
          piSessionFile: "/Users/chenda/.pi/agent/sessions/ws-2-row.jsonl",
          warnings: ["other warning"],
        }),
      ];
    });

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
    expect(response.sessions[0]).not.toHaveProperty("piSessionFile");
    expect(response.sessions[0]).not.toHaveProperty("warnings");
    expect(response.sessions[1]).not.toHaveProperty("piSessionFile");
    expect(response.sessions[1]).not.toHaveProperty("warnings");
  });

  it("returns only the requested stopped bucket contents", async () => {
    const mock = createMockContext(makeWorkspace({ hostMount: "~/workspace/oppi" }));
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
