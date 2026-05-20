import type { IncomingMessage, ServerResponse } from "node:http";
import { PassThrough } from "node:stream";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { RouteContext, RouteHelpers } from "./types.js";
import type { Session, Workspace, LocalSession } from "../types.js";
import type { WorkspaceStoppedTimeBucketSnapshot } from "../storage/session-dao.js";

const localSessionState = vi.hoisted(() => ({
  snapshot: {
    sessions: [] as LocalSession[],
    lastScannedAt: 0,
  },
}));

vi.mock("../local-sessions.js", () => ({
  discoverLocalSessions: vi.fn(async () => localSessionState.snapshot),
  invalidateLocalSessionsCache: vi.fn(),
  listCatalogedLocalSessions: vi.fn(() => localSessionState.snapshot),
  validateLocalSessionPath: vi.fn(),
  validateCwdAlignment: vi.fn(() => true),
}));

import { createSessionRoutes } from "./sessions.js";

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

  const ctx = {
    storage,
    sessions: {
      getActiveSessionIds: vi.fn().mockReturnValue([]),
      getActiveSession: vi.fn(),
      getPendingAskMessage: vi.fn(),
    },
    gate: {
      getPendingForUser: vi.fn().mockReturnValue([]),
    },
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

  return { ctx, helpers, responses, errors, storage };
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

describe("workspace home session routes", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-05-13T12:00:00Z"));
    localSessionState.snapshot = { sessions: [], lastScannedAt: Date.now() };
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("requires an explicit time range for workspace home", async () => {
    const mock = createMockContext();

    const handled = await dispatch(
      mock,
      "/workspaces/ws-1/home",
      "https://localhost/workspaces/ws-1/home",
    );

    expect(handled).toBe(true);
    expect(mock.responses).toHaveLength(0);
    expect(mock.errors).toEqual([
      {
        status: 400,
        message: "sinceMs and untilMs are required and must form a valid range",
      },
    ]);
  });

  it("returns recent rows plus merged archive buckets", async () => {
    const mock = createMockContext(makeWorkspace({ hostMount: "~/workspace/oppi" }));
    const sinceMs = Date.parse("2026-05-12T00:00:00Z");
    const untilMs = Date.parse("2026-05-13T12:00:00Z");

    mock.storage.listWorkspaceTimeRangeSessionSnapshots.mockReturnValue([
      makeSession({
        id: "recent-managed",
        status: "ready",
        lastActivity: untilMs - 1_000,
        piSessionFile: "/Users/chenda/.pi/agent/sessions/recent-managed.jsonl",
        warnings: ["local warning"],
      }),
    ]);
    mock.storage.listWorkspaceStoppedTimeBuckets.mockReturnValue([
      {
        bucketId: "day:2026-05-10",
        bucketKind: "day",
        startMs: Date.parse("2026-05-10T00:00:00Z"),
        endMs: Date.parse("2026-05-11T00:00:00Z"),
        itemCount: 2,
        latestActivity: Date.parse("2026-05-10T18:00:00Z"),
      },
    ]);
    localSessionState.snapshot = {
      lastScannedAt: Date.now(),
      sessions: [
        makeLocalSession({
          path: "/tmp/recent.jsonl",
          piSessionId: "recent-local",
          lastModified: Date.parse("2026-05-12T18:00:00Z"),
        }),
        makeLocalSession({
          path: "/tmp/day-bucket.jsonl",
          piSessionId: "day-local",
          lastModified: Date.parse("2026-05-10T18:00:00Z"),
        }),
        makeLocalSession({
          path: "/tmp/month-bucket.jsonl",
          piSessionId: "month-local",
          lastModified: Date.parse("2026-03-01T18:00:00Z"),
        }),
      ],
    };

    const handled = await dispatch(
      mock,
      "/workspaces/ws-1/home",
      `https://localhost/workspaces/ws-1/home?sinceMs=${sinceMs}&untilMs=${untilMs}`,
    );

    expect(handled).toBe(true);
    expect(mock.errors).toHaveLength(0);
    expect(mock.responses).toHaveLength(1);

    const response = mock.responses[0]?.data as {
      sessions: Session[];
      importableSessions: LocalSession[];
      archiveBuckets: Array<{
        bucketId: string;
        itemCount: number;
        managedStoppedCount: number;
        importableLocalCount: number;
      }>;
    };

    expect(response.sessions.map((session) => session.id)).toEqual(["recent-managed"]);
    expect(response.sessions[0]).not.toHaveProperty("piSessionFile");
    expect(response.sessions[0]).not.toHaveProperty("warnings");
    expect(response.importableSessions.map((session) => session.piSessionId)).toEqual([
      "recent-local",
    ]);
    expect(
      response.archiveBuckets.map((bucket) => ({
        bucketId: bucket.bucketId,
        itemCount: bucket.itemCount,
        managedStoppedCount: bucket.managedStoppedCount,
        importableLocalCount: bucket.importableLocalCount,
      })),
    ).toEqual([
      {
        bucketId: "day:2026-05-10",
        itemCount: 3,
        managedStoppedCount: 2,
        importableLocalCount: 1,
      },
      {
        bucketId: "month:2026-03",
        itemCount: 1,
        managedStoppedCount: 0,
        importableLocalCount: 1,
      },
    ]);
  });

  it("does not expose workspace session list through GET /workspaces/:id/sessions", async () => {
    const mock = createMockContext();

    const handled = await dispatch(
      mock,
      "/workspaces/ws-1/sessions",
      "https://localhost/workspaces/ws-1/sessions?recentDays=3",
    );

    expect(handled).toBe(false);
    expect(mock.errors).toHaveLength(0);
    expect(mock.responses).toHaveLength(0);
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

  it("returns only the requested bucket contents", async () => {
    const mock = createMockContext(makeWorkspace({ hostMount: "~/workspace/oppi" }));
    const sinceMs = Date.parse("2026-05-10T00:00:00Z");
    const untilMs = Date.parse("2026-05-11T00:00:00Z");

    mock.storage.listWorkspaceTimeRangeSessionSnapshots.mockReturnValue([
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
      "/workspaces/ws-1/home",
      `https://localhost/workspaces/ws-1/home?sinceMs=${sinceMs}&untilMs=${untilMs}`,
    );

    expect(handled).toBe(true);
    expect(mock.errors).toHaveLength(0);

    const response = mock.responses[0]?.data as {
      workspaceId: string;
      sinceMs: number;
      untilMs: number;
      sessions: Session[];
      importableSessions: LocalSession[];
    };

    expect(response.workspaceId).toBe("ws-1");
    expect(response.sinceMs).toBe(sinceMs);
    expect(response.untilMs).toBe(untilMs);
    expect(response.sessions.map((session) => session.id)).toEqual(["stopped-in-bucket"]);
    expect(response.importableSessions.map((session) => session.piSessionId)).toEqual([
      "local-in-bucket",
    ]);
  });
});
