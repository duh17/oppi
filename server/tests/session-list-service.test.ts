import { beforeEach, describe, expect, it, vi } from "vitest";

import type { LocalSession, Session, Workspace } from "../src/types.js";
import type { WorkspaceStoppedTimeBucketSnapshot } from "../src/storage/session-dao.js";

const localSessionState = vi.hoisted(() => ({
  snapshot: {
    sessions: [] as LocalSession[],
    lastScannedAt: 0,
  },
}));

vi.mock("../src/local-sessions.js", () => ({
  collectKnownLocalSessionIdentities: vi.fn(() => ({ files: new Set(), piSessionIds: new Set() })),
  discoverLocalSessions: vi.fn(async () => localSessionState.snapshot.sessions),
  listCatalogedLocalSessions: vi.fn(() => localSessionState.snapshot),
  validateCwdAlignment: vi.fn(() => true),
}));

import { discoverLocalSessions } from "../src/local-sessions.js";
import { SessionListService, type SessionListServiceDeps } from "../src/session-list-service.js";

function makeWorkspace(overrides: Partial<Workspace> = {}): Workspace {
  return {
    id: "ws-1",
    name: "Workspace",
    ...overrides,
  } as Workspace;
}

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "sess-1",
    workspaceId: "ws-1",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
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
    createdAt: 1,
    lastModified: 1,
    ...overrides,
  };
}

function makeService(
  options: {
    workspaces?: Workspace[];
    recentSessions?: Record<string, Session[]>;
    allSessions?: Record<string, Session[]>;
    stoppedSessions?: Record<string, Session[]>;
    stoppedBuckets?: Record<string, WorkspaceStoppedTimeBucketSnapshot[]>;
    knownSessions?: Session[];
    activeSessions?: Session[];
    pendingCounts?: Record<string, number>;
    dataDir?: string;
  } = {},
): {
  service: SessionListService;
  deps: SessionListServiceDeps;
} {
  const activeById = new Map(
    (options.activeSessions ?? []).map((session) => [session.id, session]),
  );
  const pendingCounts = options.pendingCounts ?? {};
  const deps: SessionListServiceDeps = {
    storage: {
      getDataDir: vi.fn(() => options.dataDir ?? "/tmp/oppi-session-list-service-tests"),
      listSessions: vi.fn(() => options.knownSessions ?? []),
      listWorkspaces: vi.fn(() => options.workspaces ?? [makeWorkspace()]),
      listRecentWorkspaceSessionSnapshots: vi.fn(
        (workspaceId: string) => options.recentSessions?.[workspaceId] ?? [],
      ),
      listAllWorkspaceSessionSnapshots: vi.fn(
        (workspaceId: string) => options.allSessions?.[workspaceId] ?? [],
      ),
      listStoppedWorkspaceTimeRangeSessionSnapshots: vi.fn(
        (workspaceId: string) => options.stoppedSessions?.[workspaceId] ?? [],
      ),
      listWorkspaceStoppedTimeBuckets: vi.fn(
        (workspaceId: string) => options.stoppedBuckets?.[workspaceId] ?? [],
      ),
    },
    sessionRuntimes: {
      getActiveSessionIds: vi.fn(() => new Set(activeById.keys())),
      getActiveSession: vi.fn((sessionId: string) => activeById.get(sessionId)),
      getPendingUIRequestMessages: vi.fn((sessionId: string) =>
        Array.from({ length: pendingCounts[sessionId] ?? 0 }, (_, index) => ({
          type: "extension_ui_request" as const,
          id: `${sessionId}-ask-${index}`,
          sessionId,
          method: "ask" as const,
          questions: [
            { id: "q1", question: "Pick one", options: [{ value: "yes", label: "Yes" }] },
          ],
        })),
      ),
    },
    ensureSessionContextWindow: (session) => ({
      ...session,
      contextWindow: session.contextWindow ?? 200_000,
    }),
  };

  return { service: new SessionListService(deps), deps };
}

describe("SessionListService", () => {
  beforeEach(() => {
    localSessionState.snapshot = { sessions: [], lastScannedAt: Date.now() };
    vi.clearAllMocks();
  });

  describe("listRecentWorkspaceSessionSummaries", () => {
    it("aggregates recent workspace summaries with live sessions and attention counts", () => {
      const workspaceOne = makeWorkspace({ id: "ws-1" });
      const workspaceTwo = makeWorkspace({ id: "ws-2" });
      const nowMs = Date.parse("2026-05-13T12:00:00Z");
      const { service, deps } = makeService({
        workspaces: [workspaceOne, workspaceTwo],
        recentSessions: {
          "ws-1": [
            makeSession({
              id: "stored-ready",
              workspaceId: "ws-1",
              status: "ready",
              lastActivity: nowMs,
              piSessionFile: "/tmp/hidden.jsonl",
              warnings: ["hidden"],
            }),
          ],
          "ws-2": [],
        },
        activeSessions: [
          makeSession({
            id: "live-busy",
            workspaceId: "ws-2",
            status: "busy",
            lastActivity: nowMs + 1_000,
          }),
        ],
        pendingCounts: { "live-busy": 2 },
      });

      const result = service.listRecentWorkspaceSessionSummaries({ recentDays: 3, nowMs });

      expect(deps.storage.listRecentWorkspaceSessionSnapshots).toHaveBeenCalledWith(
        "ws-1",
        3,
        nowMs,
      );
      expect(deps.storage.listRecentWorkspaceSessionSnapshots).toHaveBeenCalledWith(
        "ws-2",
        3,
        nowMs,
      );
      expect(result.sessions.map((session) => session.id)).toEqual(["live-busy", "stored-ready"]);
      expect(result.sessions[0]).toMatchObject({
        id: "live-busy",
        pendingAskCount: 2,
        contextWindow: 200_000,
      });
      expect(result.sessions[1]).toMatchObject({ id: "stored-ready", pendingAskCount: 0 });
      expect(result.sessions[1]).not.toHaveProperty("piSessionFile");
      expect(result.sessions[1]).not.toHaveProperty("warnings");
    });
  });

  describe("listWorkspaceSessionRows", () => {
    it("builds active and stopped workspace rows with live and local sessions", () => {
      const workspace = makeWorkspace({ hostMount: "~/workspace/oppi" });
      const sinceMs = Date.parse("2026-05-13T00:00:00Z");
      const untilMs = Date.parse("2026-05-14T00:00:00Z");
      const nowMs = Date.parse("2026-05-13T12:00:00Z");
      localSessionState.snapshot = {
        lastScannedAt: nowMs,
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
          makeLocalSession({
            path: "/tmp/tui-outside.jsonl",
            piSessionId: "tui-outside",
            lastModified: untilMs + 10_000,
          }),
        ],
      };
      const { service, deps } = makeService({
        allSessions: {
          "ws-1": [
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
            makeSession({
              id: "task-record",
              status: "busy",
              runtime: "pi-tui",
              name: "Agent#abcdef12",
              lastActivity: sinceMs + 50_000,
            }),
          ],
        },
        stoppedSessions: {
          "ws-1": [
            makeSession({ id: "stopped-today", status: "stopped", lastActivity: sinceMs + 10_000 }),
            makeSession({ id: "active-leak", status: "busy", lastActivity: sinceMs + 20_000 }),
            makeSession({
              id: "stopped-outside",
              status: "stopped",
              lastActivity: untilMs + 1_000,
            }),
          ],
        },
        activeSessions: [
          makeSession({ id: "live-busy", status: "busy", lastActivity: sinceMs + 5_000 }),
        ],
        pendingCounts: { "live-busy": 1 },
      });

      const result = service.listWorkspaceSessionRows({
        workspace,
        statuses: new Set(["active", "stopped"]),
        timeRange: { sinceMs, untilMs },
        nowMs,
      });

      expect(result).toMatchObject({ workspaceId: "ws-1", sinceMs, untilMs, serverNow: nowMs });
      expect(result.active?.map((session) => session.id)).toEqual(["live-busy", "old-ready"]);
      expect(result.active?.[0]).toMatchObject({ id: "live-busy", pendingAskCount: 1 });
      expect(result.active?.map((session) => session.id)).not.toContain("task-record");
      expect(result.stopped?.map((session) => session.id)).toEqual([
        "/tmp/tui-today.jsonl",
        "stopped-today",
      ]);
      expect(result.stopped?.[0]).toMatchObject({
        source: "tui",
        piSessionId: "tui-today",
        status: "stopped",
        pendingAskCount: 0,
      });
      expect(result.stopped?.map((session) => session.id)).not.toContain("active-leak");
      expect(result.stopped?.map((session) => session.id)).not.toContain("stopped-outside");
      expect(result.stopped?.map((session) => session.id)).not.toContain("/tmp/tui-old.jsonl");
      expect(deps.storage.listStoppedWorkspaceTimeRangeSessionSnapshots).toHaveBeenCalledWith(
        "ws-1",
        sinceMs,
        untilMs,
        undefined,
      );
    });

    it("does not expose importable local sessions for hostless workspaces", () => {
      const sinceMs = Date.parse("2026-05-13T00:00:00Z");
      const untilMs = Date.parse("2026-05-14T00:00:00Z");
      const nowMs = Date.parse("2026-05-13T12:00:00Z");
      localSessionState.snapshot = {
        lastScannedAt: nowMs,
        sessions: [
          makeLocalSession({
            path: "/tmp/hostless-tui.jsonl",
            piSessionId: "hostless-tui",
            lastModified: sinceMs + 15_000,
          }),
        ],
      };
      const { service } = makeService();

      const result = service.listWorkspaceSessionRows({
        workspace: makeWorkspace(),
        statuses: new Set(["stopped"]),
        timeRange: { sinceMs, untilMs },
        nowMs,
      });
      const buckets = service.listWorkspaceStoppedSessionBuckets({
        workspace: makeWorkspace(),
        beforeMs: untilMs,
        nowMs,
      });

      expect(result.stopped).toEqual([]);
      expect(buckets.buckets).toEqual([]);
    });
  });

  describe("listWorkspaceStoppedSessionBuckets", () => {
    it("merges managed stopped buckets with older importable local sessions", () => {
      const workspace = makeWorkspace({ hostMount: "~/workspace/oppi" });
      const beforeMs = Date.parse("2026-05-13T00:00:00Z");
      const nowMs = Date.parse("2026-05-13T12:00:00Z");
      const olderLocalActivity = Date.parse("2026-05-12T19:00:00Z");
      localSessionState.snapshot = {
        lastScannedAt: nowMs,
        sessions: [
          makeLocalSession({
            path: "/tmp/tui-old.jsonl",
            piSessionId: "tui-old",
            lastModified: olderLocalActivity,
          }),
          makeLocalSession({
            path: "/tmp/tui-visible.jsonl",
            piSessionId: "tui-visible",
            lastModified: beforeMs + 1_000,
          }),
        ],
      };
      const { service, deps } = makeService({
        stoppedBuckets: {
          "ws-1": [
            {
              bucketId: "day:2026-05-12",
              bucketKind: "day",
              startMs: Date.parse("2026-05-12T00:00:00Z"),
              endMs: Date.parse("2026-05-13T00:00:00Z"),
              itemCount: 1,
              latestActivity: Date.parse("2026-05-12T18:00:00Z"),
            },
          ],
        },
      });

      const result = service.listWorkspaceStoppedSessionBuckets({ workspace, beforeMs, nowMs });

      expect(deps.storage.listWorkspaceStoppedTimeBuckets).toHaveBeenCalledWith(
        "ws-1",
        beforeMs,
        nowMs,
        undefined,
      );
      expect(discoverLocalSessions).not.toHaveBeenCalled();
      expect(result).toMatchObject({
        workspaceId: "ws-1",
        status: "stopped",
        beforeMs,
        serverNow: nowMs,
      });
      expect(result.buckets).toEqual([
        expect.objectContaining({
          bucketId: "day:2026-05-12",
          itemCount: 2,
          managedStoppedCount: 1,
          importableLocalCount: 1,
          latestActivity: olderLocalActivity,
        }),
      ]);
    });
  });
});
