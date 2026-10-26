import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { LocalSession, Session, Workspace } from "../src/types.js";

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
  isControlSessionLocalArtifact: vi.fn(() => false),
  validateCwdAlignment: vi.fn(() => true),
}));

import { discoverLocalSessions } from "../src/local-sessions.js";
import { SessionListService, type SessionListServiceDeps } from "../src/session-list-service.js";
import { Storage } from "../src/storage.js";

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
    timeRangeSessions?: Record<string, Session[]>;
    stoppedSessions?: Record<string, Session[]>;
    stoppedActivityTimes?: Record<string, number[]>;
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
      listWorkspaceTimeRangeSessionSnapshots: vi.fn(
        (workspaceId: string) => options.timeRangeSessions?.[workspaceId] ?? [],
      ),
      listStoppedWorkspaceTimeRangeSessionSnapshots: vi.fn(
        (workspaceId: string) => options.stoppedSessions?.[workspaceId] ?? [],
      ),
      listWorkspaceStoppedActivityTimes: vi.fn(
        (workspaceId: string) => options.stoppedActivityTimes?.[workspaceId] ?? [],
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
    it("aggregates recent workspace summaries with live sessions and attention counts", async () => {
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
      expect(result.sessions[1]).not.toHaveProperty("piSessionId");
      expect(result.sessions[1]).not.toHaveProperty("warnings");
    });

    it("uses bounded workspace queries and exactly filters stored and live active rows", async () => {
      const sinceMs = 1_000;
      const untilMs = 2_000;
      const { service, deps } = makeService({
        timeRangeSessions: {
          "ws-1": [
            makeSession({ id: "stored-before", status: "ready", lastActivity: sinceMs - 1 }),
            makeSession({ id: "stored-until", status: "ready", lastActivity: untilMs }),
          ],
        },
        activeSessions: [
          makeSession({ id: "live-inside", status: "busy", lastActivity: sinceMs }),
          makeSession({ id: "live-after", status: "busy", lastActivity: untilMs + 1 }),
        ],
      });

      const result = service.listRecentWorkspaceSessionSummaries({
        recentDays: 0,
        sinceMs,
        untilMs,
      });

      expect(deps.storage.listWorkspaceTimeRangeSessionSnapshots).toHaveBeenCalledWith(
        "ws-1",
        sinceMs,
        untilMs + 1,
      );
      expect(deps.storage.listAllWorkspaceSessionSnapshots).not.toHaveBeenCalled();
      expect(result.sessions.map((session) => session.id)).toEqual(["stored-until", "live-inside"]);
    });

    it("uses safe SQLite bounds for one-sided activity ranges", async () => {
      const { service, deps } = makeService();

      service.listRecentWorkspaceSessionSummaries({ recentDays: 0, sinceMs: 1_000 });
      expect(deps.storage.listWorkspaceTimeRangeSessionSnapshots).toHaveBeenLastCalledWith(
        "ws-1",
        1_000,
        Number.MAX_SAFE_INTEGER,
      );

      service.listRecentWorkspaceSessionSummaries({ recentDays: 0, untilMs: 2_000 });
      expect(deps.storage.listWorkspaceTimeRangeSessionSnapshots).toHaveBeenLastCalledWith(
        "ws-1",
        Number.MIN_SAFE_INTEGER,
        2_001,
      );
      expect(deps.storage.listAllWorkspaceSessionSnapshots).not.toHaveBeenCalled();
    });
  });

  describe("live session workspace names", () => {
    it("shows the workspace's current name on live rows saved before a rename", async () => {
      const workspace = makeWorkspace({ id: "ws-1", name: "oppi" });
      const live = makeSession({ id: "live", status: "busy", workspaceName: "pios" });
      const { service } = makeService({
        workspaces: [workspace],
        allSessions: { "ws-1": [makeSession({ id: "live", workspaceName: "oppi" })] },
        recentSessions: { "ws-1": [] },
        activeSessions: [live],
      });

      const workspaceRows = await service.listWorkspaceSessionRows({
        workspace,
        statuses: new Set(["active"]),
      });
      expect(workspaceRows.active?.map((row) => row.workspaceName)).toEqual(["oppi"]);

      live.workspaceName = "pios";
      const recent = service.listRecentWorkspaceSessionSummaries({ recentDays: 3 });
      expect(recent.sessions.map((row) => [row.id, row.workspaceName])).toEqual([["live", "oppi"]]);
    });
  });

  describe("listWorkspaceSessionRows", () => {
    it("builds active and stopped workspace rows with live and local sessions", async () => {
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

      const result = await service.listWorkspaceSessionRows({
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

    it("does not expose importable local sessions for hostless workspaces", async () => {
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

      const result = await service.listWorkspaceSessionRows({
        workspace: makeWorkspace(),
        statuses: new Set(["stopped"]),
        timeRange: { sinceMs, untilMs },
        nowMs,
      });
      const buckets = await service.listWorkspaceStoppedSessionBuckets({
        workspace: makeWorkspace(),
        beforeMs: untilMs,
        nowMs,
      });

      expect(result.stopped).toEqual([]);
      expect(buckets.buckets).toEqual([]);
    });
  });

  describe("listWorkspaceStoppedSessionBuckets", () => {
    it("merges managed stopped buckets with older importable local sessions", async () => {
      const workspace = makeWorkspace({ hostMount: "~/workspace/oppi" });
      // Local times, so both sessions fall on 2026-05-12 in any server time zone.
      const beforeMs = new Date(2026, 4, 13).getTime();
      const nowMs = new Date(2026, 4, 13, 12).getTime();
      const olderLocalActivity = new Date(2026, 4, 12, 12).getTime();
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
      const { service } = makeService({
        stoppedActivityTimes: { "ws-1": [new Date(2026, 4, 12, 11).getTime()] },
      });

      const result = await service.listWorkspaceStoppedSessionBuckets({
        workspace,
        beforeMs,
        nowMs,
      });

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

    it("defers cold local-session catalog refresh off the request stack", async () => {
      localSessionState.snapshot = {
        sessions: [],
        // stale / never scanned
      } as typeof localSessionState.snapshot;
      const { service } = makeService({
        dataDir: "/tmp/oppi-session-list-defer-refresh",
      });
      const nowMs = Date.now();

      await service.listWorkspaceSessionRows({
        workspace: makeWorkspace({ hostMount: "/tmp/project" }),
        statuses: new Set(["stopped"]),
        timeRange: { sinceMs: nowMs - 1_000, untilMs: nowMs },
        nowMs,
      });

      // Must not invoke discover inline while shaping the HTTP response.
      expect(discoverLocalSessions).not.toHaveBeenCalled();
      await vi.waitFor(() => {
        expect(discoverLocalSessions).toHaveBeenCalledTimes(1);
      });
    });
  });
});

// Older-history day sections must cover the whole local calendar day: 25 hours when
// clocks fall back and 23 when they spring forward. Oppi rows (SQLite) and local Pi
// rows must land in the same section, and opening it must load exactly what it counts.
describe("older-history day sections across daylight-saving changes", () => {
  const LA = "America/Los_Angeles";
  let originalTz: string | undefined;
  let dataDir: string;
  let storage: Storage;
  let service: SessionListService;
  const workspace = makeWorkspace({ hostMount: "/tmp/oppi-dst-project" });

  beforeEach(() => {
    originalTz = process.env.TZ;
    process.env.TZ = LA;
    dataDir = mkdtempSync(join(tmpdir(), "oppi-dst-sections-"));
    storage = new Storage(dataDir);
    service = new SessionListService({
      storage,
      sessionRuntimes: {
        getActiveSessionIds: () => new Set(),
        getActiveSession: () => undefined,
        getPendingUIRequestMessages: () => [],
      },
      ensureSessionContextWindow: (session) => session,
    });
  });

  afterEach(() => {
    if (originalTz === undefined) {
      delete process.env.TZ;
    } else {
      process.env.TZ = originalTz;
    }
    rmSync(dataDir, { recursive: true, force: true });
  });

  function stopOppiSession(id: string, lastActivity: number): void {
    storage.saveSession(
      makeSession({ id, status: "stopped", createdAt: lastActivity, lastActivity }),
    );
  }

  function addLocalPiSession(path: string, lastModified: number): void {
    localSessionState.snapshot.sessions.push(
      makeLocalSession({ path, piSessionId: path, cwd: workspace.hostMount, lastModified }),
    );
  }

  async function openSection(bucket: { startMs: number; endMs: number }, nowMs: number) {
    const rows = await service.listWorkspaceSessionRows({
      workspace,
      statuses: new Set(["stopped"]),
      timeRange: { sinceMs: bucket.startMs, untilMs: bucket.endMs },
      nowMs,
    });
    return (rows.stopped ?? []).map((row) => row.id).sort();
  }

  it("keeps the last hour of the 25-hour fall-back day in that day's section", async () => {
    const nowMs = Date.parse("2026-11-05T12:00:00-08:00");
    localSessionState.snapshot = { sessions: [], lastScannedAt: nowMs };
    // 23:30 local on Sun 2026-11-01, after clocks fell back to PST.
    stopOppiSession("late-oppi", Date.parse("2026-11-01T23:30:00-08:00"));
    addLocalPiSession("/tmp/late-pi.jsonl", Date.parse("2026-11-01T23:45:00-08:00"));
    stopOppiSession("next-day-oppi", Date.parse("2026-11-02T00:15:00-08:00"));

    const result = await service.listWorkspaceStoppedSessionBuckets({
      workspace,
      beforeMs: Date.parse("2026-11-03T00:00:00-08:00"),
      nowMs,
    });

    const fallBack = result.buckets.find((bucket) => bucket.bucketId === "day:2026-11-01");
    expect(fallBack).toEqual({
      bucketId: "day:2026-11-01",
      bucketKind: "day",
      startMs: Date.parse("2026-11-01T00:00:00-07:00"),
      endMs: Date.parse("2026-11-02T00:00:00-08:00"),
      itemCount: 2,
      managedStoppedCount: 1,
      importableLocalCount: 1,
      latestActivity: Date.parse("2026-11-01T23:45:00-08:00"),
    });
    expect(fallBack!.endMs - fallBack!.startMs).toBe(25 * 3_600_000);
    expect(await openSection(fallBack!, nowMs)).toEqual(["/tmp/late-pi.jsonl", "late-oppi"]);

    const nextDay = result.buckets.find((bucket) => bucket.bucketId === "day:2026-11-02");
    expect(nextDay?.startMs).toBe(fallBack!.endMs);
    expect(nextDay?.itemCount).toBe(1);
    expect(await openSection(nextDay!, nowMs)).toEqual(["next-day-oppi"]);
  });

  it("ends the 23-hour spring-forward day at the next local midnight", async () => {
    const nowMs = Date.parse("2026-03-12T12:00:00-07:00");
    localSessionState.snapshot = { sessions: [], lastScannedAt: nowMs };
    stopOppiSession("late-oppi", Date.parse("2026-03-08T23:30:00-07:00"));
    addLocalPiSession("/tmp/late-pi.jsonl", Date.parse("2026-03-08T23:40:00-07:00"));
    stopOppiSession("next-day-oppi", Date.parse("2026-03-09T00:30:00-07:00"));

    const result = await service.listWorkspaceStoppedSessionBuckets({
      workspace,
      beforeMs: Date.parse("2026-03-10T00:00:00-07:00"),
      nowMs,
    });

    const springForward = result.buckets.find((bucket) => bucket.bucketId === "day:2026-03-08");
    expect(springForward).toMatchObject({
      startMs: Date.parse("2026-03-08T00:00:00-08:00"),
      endMs: Date.parse("2026-03-09T00:00:00-07:00"),
      itemCount: 2,
      managedStoppedCount: 1,
      importableLocalCount: 1,
    });
    expect(springForward!.endMs - springForward!.startMs).toBe(23 * 3_600_000);
    expect(await openSection(springForward!, nowMs)).toEqual(["/tmp/late-pi.jsonl", "late-oppi"]);

    const nextDay = result.buckets.find((bucket) => bucket.bucketId === "day:2026-03-09");
    expect(nextDay).toMatchObject({ startMs: springForward!.endMs, itemCount: 1 });
    expect(await openSection(nextDay!, nowMs)).toEqual(["next-day-oppi"]);
  });

  it("never repeats a recent row in a section when the server's time zone differs", async () => {
    // The server runs in UTC; the phone in Los Angeles asks for older history before its
    // own midnight (08:00Z), which falls inside the server's day:2026-11-03.
    process.env.TZ = "UTC";
    const nowMs = Date.parse("2026-11-05T12:00:00-08:00");
    const beforeMs = Date.parse("2026-11-03T00:00:00-08:00");
    localSessionState.snapshot = { sessions: [], lastScannedAt: nowMs };
    stopOppiSession("older-oppi", Date.parse("2026-11-03T05:00:00Z"));
    addLocalPiSession("/tmp/older-pi.jsonl", Date.parse("2026-11-03T06:00:00Z"));
    stopOppiSession("recent-oppi", Date.parse("2026-11-03T10:00:00Z"));
    addLocalPiSession("/tmp/recent-pi.jsonl", Date.parse("2026-11-03T11:00:00Z"));

    const recent = await service.listWorkspaceSessionRows({
      workspace,
      statuses: new Set(["stopped"]),
      timeRange: { sinceMs: beforeMs, untilMs: nowMs },
      nowMs,
    });
    const { buckets } = await service.listWorkspaceStoppedSessionBuckets({
      workspace,
      beforeMs,
      nowMs,
    });
    const opened = await Promise.all(buckets.map((bucket) => openSection(bucket, nowMs)));

    expect((recent.stopped ?? []).map((row) => row.id).sort()).toEqual([
      "/tmp/recent-pi.jsonl",
      "recent-oppi",
    ]);
    expect(opened.flat().sort()).toEqual(["/tmp/older-pi.jsonl", "older-oppi"]);
    expect(buckets.map((bucket) => bucket.itemCount)).toEqual(opened.map((ids) => ids.length));
    expect(buckets.find((bucket) => bucket.bucketId === "day:2026-11-03")?.endMs).toBe(beforeMs);
  });
});
