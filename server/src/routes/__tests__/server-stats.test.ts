import { describe, expect, test } from "vitest";

import type { Session, Workspace } from "../../types.js";
import {
  aggregateStats,
  getActiveSessions,
  parseRange,
  type AggregateInput,
} from "../server-stats.js";

// ─── Helpers ───

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "s-1",
    status: "stopped",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 10,
    tokens: { input: 5000, output: 3000 },
    cost: 0.5,
    model: "anthropic/claude-sonnet-4-20250514",
    workspaceId: "ws-1",
    workspaceName: "coding",
    ...overrides,
  };
}

function makeWorkspace(overrides: Partial<Workspace> = {}): Workspace {
  return {
    id: "ws-1",
    name: "coding",
    skills: [],
    systemPromptMode: "append",
    createdAt: Date.now(),
    updatedAt: Date.now(),
    ...overrides,
  };
}

const DAY_MS = 24 * 60 * 60 * 1000;

// ─── parseRange ───

describe("parseRange", () => {
  test("defaults to 7 for null", () => {
    expect(parseRange(null)).toBe(7);
  });

  test("defaults to 7 for empty string", () => {
    expect(parseRange("")).toBe(7);
  });

  test("accepts 7, 30, 90", () => {
    expect(parseRange("7")).toBe(7);
    expect(parseRange("30")).toBe(30);
    expect(parseRange("90")).toBe(90);
  });

  test("rejects invalid values", () => {
    expect(parseRange("14")).toBe(7);
    expect(parseRange("abc")).toBe(7);
    expect(parseRange("-1")).toBe(7);
  });
});

// ─── getActiveSessions ───

describe("getActiveSessions", () => {
  test("without activeSessionIds, filters to non-stopped, non-error sessions (backward compat)", () => {
    const sessions = [
      makeSession({ id: "s-1", status: "busy" }),
      makeSession({ id: "s-2", status: "stopped" }),
      makeSession({ id: "s-3", status: "ready" }),
      makeSession({ id: "s-4", status: "error" }),
      makeSession({ id: "s-5", status: "starting" }),
    ];

    const active = getActiveSessions(sessions);
    expect(active.map((s) => s.id)).toEqual(["s-1", "s-3", "s-5"]);
  });

  test("with activeSessionIds, excludes zombie sessions not in memory", () => {
    const sessions = [
      makeSession({ id: "s-1", status: "busy" }),
      makeSession({ id: "s-2", status: "stopped" }),
      makeSession({ id: "s-3", status: "ready" }),
      makeSession({ id: "s-4", status: "error" }),
      makeSession({ id: "s-5", status: "starting" }), // zombie — not in active set
    ];

    // Only s-1 and s-3 are genuinely in memory
    const activeIds = new Set(["s-1", "s-3"]);
    const active = getActiveSessions(sessions, activeIds);
    expect(active.map((s) => s.id)).toEqual(["s-1", "s-3"]);
  });

  test("maps fields correctly", () => {
    const sessions = [
      makeSession({
        id: "s-1",
        status: "busy",
        model: "anthropic/opus",
        cost: 1.234,
        name: "my session",
        thinkingLevel: "high",
        parentSessionId: "s-0",
        contextTokens: 50000,
        contextWindow: 200000,
        createdAt: 1000,
      }),
    ];

    const [s] = getActiveSessions(sessions);
    expect(s).toEqual({
      id: "s-1",
      status: "busy",
      model: "anthropic/opus",
      cost: 1.23,
      name: "my session",
      thinkingLevel: "high",
      parentSessionId: "s-0",
      contextTokens: 50000,
      contextWindow: 200000,
      createdAt: 1000,
    });
  });

  test("returns empty for no active sessions", () => {
    const sessions = [makeSession({ status: "stopped" }), makeSession({ status: "error" })];
    expect(getActiveSessions(sessions)).toEqual([]);
  });
});

// ─── aggregateStats ───

describe("aggregateStats", () => {
  const now = new Date("2026-03-20T12:00:00Z").getTime();

  function aggregate(overrides: Partial<AggregateInput> = {}): ReturnType<typeof aggregateStats> {
    return aggregateStats({
      sessions: [],
      workspaces: [makeWorkspace()],
      rangeDays: 7,
      now,
      ...overrides,
    });
  }

  test("returns empty for no sessions", () => {
    const result = aggregate();
    expect(result.daily).toEqual([]);
    expect(result.modelBreakdown).toEqual([]);
    expect(result.workspaceBreakdown).toEqual([]);
    expect(result.totals).toEqual({ sessions: 0, cost: 0, tokens: 0 });
  });

  test("filters sessions outside range", () => {
    const sessions = [
      makeSession({ id: "in-range", createdAt: now - 1 * DAY_MS, cost: 1 }),
      makeSession({ id: "out-of-range", createdAt: now - 10 * DAY_MS, cost: 5 }),
    ];

    const result = aggregate({ sessions });
    expect(result.totals.sessions).toBe(1);
    expect(result.totals.cost).toBe(1);
  });

  test("aggregates daily breakdown", () => {
    const day1 = new Date("2026-03-18T10:00:00Z").getTime();
    const day2 = new Date("2026-03-19T14:00:00Z").getTime();
    const sessions = [
      makeSession({
        id: "s1",
        createdAt: day1,
        cost: 1,
        model: "sonnet",
        tokens: { input: 1000, output: 500 },
      }),
      makeSession({
        id: "s2",
        createdAt: day1,
        cost: 2,
        model: "opus",
        tokens: { input: 2000, output: 1000 },
      }),
      makeSession({
        id: "s3",
        createdAt: day2,
        cost: 0.5,
        model: "sonnet",
        tokens: { input: 500, output: 200 },
      }),
    ];

    const result = aggregate({ sessions });

    expect(result.daily).toHaveLength(2);

    // Day 1
    expect(result.daily[0].date).toBe("2026-03-18");
    expect(result.daily[0].sessions).toBe(2);
    expect(result.daily[0].cost).toBe(3);
    expect(result.daily[0].tokens).toBe(4500);
    expect(result.daily[0].byModel["sonnet"]).toEqual({ sessions: 1, cost: 1, tokens: 1500 });
    expect(result.daily[0].byModel["opus"]).toEqual({ sessions: 1, cost: 2, tokens: 3000 });

    // Day 2
    expect(result.daily[1].date).toBe("2026-03-19");
    expect(result.daily[1].sessions).toBe(1);
    expect(result.daily[1].cost).toBe(0.5);
  });

  test("daily entries are sorted ascending by date", () => {
    const sessions = [
      makeSession({
        id: "s1",
        createdAt: new Date("2026-03-20T01:00:00Z").getTime(),
        cost: 1,
        model: "a",
      }),
      makeSession({
        id: "s2",
        createdAt: new Date("2026-03-14T01:00:00Z").getTime(),
        cost: 1,
        model: "a",
      }),
      makeSession({
        id: "s3",
        createdAt: new Date("2026-03-17T01:00:00Z").getTime(),
        cost: 1,
        model: "a",
      }),
    ];

    const result = aggregate({ sessions });
    const dates = result.daily.map((d) => d.date);
    expect(dates).toEqual(["2026-03-14", "2026-03-17", "2026-03-20"]);
  });

  test("aggregates model breakdown with shares", () => {
    const sessions = [
      makeSession({
        id: "s1",
        createdAt: now - DAY_MS,
        cost: 3,
        model: "sonnet",
        tokens: { input: 1000, output: 1000 },
      }),
      makeSession({
        id: "s2",
        createdAt: now - DAY_MS,
        cost: 7,
        model: "opus",
        tokens: { input: 5000, output: 2000 },
      }),
    ];

    const result = aggregate({ sessions });
    expect(result.modelBreakdown).toHaveLength(2);

    // Sorted by cost desc → opus first
    expect(result.modelBreakdown[0]).toEqual({
      model: "opus",
      sessions: 1,
      cost: 7,
      tokens: 7000,
      share: 0.7,
    });
    expect(result.modelBreakdown[1]).toEqual({
      model: "sonnet",
      sessions: 1,
      cost: 3,
      tokens: 2000,
      share: 0.3,
    });
  });

  test("aggregates workspace breakdown", () => {
    const workspaces = [
      makeWorkspace({ id: "ws-1", name: "coding" }),
      makeWorkspace({ id: "ws-2", name: "research" }),
    ];
    const sessions = [
      makeSession({ id: "s1", createdAt: now - DAY_MS, cost: 5, workspaceId: "ws-1" }),
      makeSession({ id: "s2", createdAt: now - DAY_MS, cost: 3, workspaceId: "ws-1" }),
      makeSession({ id: "s3", createdAt: now - DAY_MS, cost: 10, workspaceId: "ws-2" }),
    ];

    const result = aggregate({ sessions, workspaces });
    expect(result.workspaceBreakdown).toHaveLength(2);

    // Sorted by cost desc → ws-2 first
    expect(result.workspaceBreakdown[0]).toEqual({
      id: "ws-2",
      name: "research",
      sessions: 1,
      cost: 10,
    });
    expect(result.workspaceBreakdown[1]).toEqual({
      id: "ws-1",
      name: "coding",
      sessions: 2,
      cost: 8,
    });
  });

  test("workspace breakdown falls back to id when workspace not found", () => {
    const sessions = [
      makeSession({ id: "s1", createdAt: now - DAY_MS, cost: 1, workspaceId: "deleted-ws" }),
    ];

    const result = aggregate({ sessions, workspaces: [] });
    expect(result.workspaceBreakdown[0].name).toBe("deleted-ws");
  });

  test("sessions without workspaceId grouped as 'unknown'", () => {
    const sessions = [
      makeSession({ id: "s1", createdAt: now - DAY_MS, cost: 2, workspaceId: undefined }),
    ];

    const result = aggregate({ sessions });
    expect(result.workspaceBreakdown[0].id).toBe("unknown");
  });

  test("sessions without model grouped as 'unknown'", () => {
    const sessions = [
      makeSession({ id: "s1", createdAt: now - DAY_MS, cost: 1, model: undefined }),
    ];

    const result = aggregate({ sessions });
    expect(result.modelBreakdown[0].model).toBe("unknown");
  });

  test("totals sum all sessions in range", () => {
    const sessions = [
      makeSession({
        id: "s1",
        createdAt: now - 1 * DAY_MS,
        cost: 1.5,
        tokens: { input: 1000, output: 500 },
      }),
      makeSession({
        id: "s2",
        createdAt: now - 2 * DAY_MS,
        cost: 2.3,
        tokens: { input: 2000, output: 1000 },
      }),
      makeSession({
        id: "s3",
        createdAt: now - 2 * DAY_MS,
        cost: 0.7,
        tokens: { input: 500, output: 200 },
      }),
    ];

    const result = aggregate({ sessions });
    expect(result.totals).toEqual({ sessions: 3, cost: 4.5, tokens: 5200 });
  });

  test("respects range parameter", () => {
    const sessions = [
      makeSession({ id: "recent", createdAt: now - 5 * DAY_MS, cost: 1 }),
      makeSession({ id: "older", createdAt: now - 15 * DAY_MS, cost: 2 }),
      makeSession({ id: "oldest", createdAt: now - 60 * DAY_MS, cost: 3 }),
    ];

    expect(aggregate({ sessions, rangeDays: 7 }).totals.sessions).toBe(1);
    expect(aggregate({ sessions, rangeDays: 30 }).totals.sessions).toBe(2);
    expect(aggregate({ sessions, rangeDays: 90 }).totals.sessions).toBe(3);
  });

  test("share is 0 when total cost is 0", () => {
    const sessions = [makeSession({ id: "s1", createdAt: now - DAY_MS, cost: 0, model: "free" })];

    const result = aggregate({ sessions });
    expect(result.modelBreakdown[0].share).toBe(0);
  });
});
