import { describe, expect, it } from "vitest";
import type { Session, Workspace } from "../src/types.js";
import {
  parseRange,
  getActiveSessions,
  aggregateStats,
  aggregateDailyDetail,
} from "../src/routes/server-stats.js";

// ─── Helpers ───

/** Fixed "now": 2025-06-15T12:00:00.000Z */
const NOW = new Date("2025-06-15T12:00:00.000Z").getTime();
const ONE_DAY = 24 * 60 * 60 * 1000;

function makeSession(overrides: Partial<Session> & { id: string }): Session {
  return {
    workspaceId: "ws-1",
    workspaceName: "default",
    name: "test session",
    status: "stopped",
    createdAt: NOW - ONE_DAY,
    lastActivity: NOW,
    model: "claude-sonnet-4-20250514",
    messageCount: 5,
    tokens: { input: 100, output: 50, cacheRead: 10, cacheWrite: 5 },
    cost: 0.12,
    ...overrides,
  };
}

function makeWorkspace(id: string, name: string): Workspace {
  return {
    id,
    name,
    skills: [],
    systemPromptMode: "append",
    createdAt: NOW - 30 * ONE_DAY,
  } as Workspace;
}

// ─── parseRange ───

describe("parseRange", () => {
  it("returns 7 for null", () => {
    expect(parseRange(null)).toBe(7);
  });

  it("returns 7 for empty string", () => {
    expect(parseRange("")).toBe(7);
  });

  it("accepts valid ranges: 7, 30, 90", () => {
    expect(parseRange("7")).toBe(7);
    expect(parseRange("30")).toBe(30);
    expect(parseRange("90")).toBe(90);
  });

  it("returns default 7 for invalid numbers", () => {
    expect(parseRange("14")).toBe(7);
    expect(parseRange("0")).toBe(7);
    expect(parseRange("365")).toBe(7);
  });

  it("returns default 7 for non-numeric strings", () => {
    expect(parseRange("abc")).toBe(7);
    expect(parseRange("7abc")).toBe(7);
  });

  it("returns default 7 for negative numbers", () => {
    expect(parseRange("-7")).toBe(7);
    expect(parseRange("-30")).toBe(7);
  });

  it("returns default 7 for floating point versions of valid ranges", () => {
    expect(parseRange("7.0")).toBe(7);
    expect(parseRange("30.5")).toBe(7);
  });
});

// ─── getActiveSessions ───

describe("getActiveSessions", () => {
  it("excludes stopped sessions", () => {
    const sessions = [
      makeSession({ id: "s1", status: "stopped" }),
      makeSession({ id: "s2", status: "ready" }),
    ];
    const active = new Set(["s1", "s2"]);
    const result = getActiveSessions(sessions, active);
    expect(result.map((s) => s.id)).toEqual(["s2"]);
  });

  it("excludes error sessions", () => {
    const sessions = [makeSession({ id: "s1", status: "error" })];
    const result = getActiveSessions(sessions, new Set(["s1"]));
    expect(result).toHaveLength(0);
  });

  it("excludes zombie sessions (on disk but not in activeSessionIds)", () => {
    const sessions = [
      makeSession({ id: "s1", status: "starting" }),
      makeSession({ id: "s2", status: "ready" }),
    ];
    // Only s2 is genuinely active in memory
    const active = new Set(["s2"]);
    const result = getActiveSessions(sessions, active);
    expect(result.map((s) => s.id)).toEqual(["s2"]);
  });

  it("includes all non-terminal sessions when activeSessionIds is undefined", () => {
    const sessions = [
      makeSession({ id: "s1", status: "starting" }),
      makeSession({ id: "s2", status: "ready" }),
      makeSession({ id: "s3", status: "busy" }),
      makeSession({ id: "s4", status: "stopping" }),
      makeSession({ id: "s5", status: "stopped" }),
      makeSession({ id: "s6", status: "error" }),
    ];
    const result = getActiveSessions(sessions);
    expect(result.map((s) => s.id)).toEqual(["s1", "s2", "s3", "s4"]);
  });

  it("rounds cost to 2 decimal places", () => {
    const sessions = [makeSession({ id: "s1", status: "ready", cost: 1.23456789 })];
    const result = getActiveSessions(sessions, new Set(["s1"]));
    expect(result[0].cost).toBe(1.23);
  });

  it("maps all expected fields", () => {
    const sessions = [
      makeSession({
        id: "s1",
        status: "busy",
        model: "gpt-4",
        cost: 0.5,
        name: "coding",
        firstMessage: "hello",
        workspaceName: "dev",
        thinkingLevel: "high",
        parentSessionId: "parent-1",
        contextTokens: 1000,
        contextWindow: 128000,
        createdAt: NOW,
      }),
    ];
    const result = getActiveSessions(sessions, new Set(["s1"]));
    expect(result[0]).toEqual({
      id: "s1",
      status: "busy",
      model: "gpt-4",
      cost: 0.5,
      name: "coding",
      firstMessage: "hello",
      workspaceName: "dev",
      thinkingLevel: "high",
      parentSessionId: "parent-1",
      contextTokens: 1000,
      contextWindow: 128000,
      createdAt: NOW,
    });
  });

  it("returns empty array for empty input", () => {
    expect(getActiveSessions([], new Set())).toEqual([]);
  });
});

// ─── aggregateStats ───

describe("aggregateStats", () => {
  it("returns zeroed result for empty sessions", () => {
    const result = aggregateStats({
      sessions: [],
      workspaces: [],
      rangeDays: 7,
      now: NOW,
    });
    expect(result.totals).toEqual({ sessions: 0, cost: 0, tokens: 0 });
    expect(result.daily).toEqual([]);
    expect(result.modelBreakdown).toEqual([]);
    expect(result.workspaceBreakdown).toEqual([]);
  });

  it("excludes sessions outside date range", () => {
    const old = makeSession({ id: "s1", createdAt: NOW - 10 * ONE_DAY });
    const recent = makeSession({ id: "s2", createdAt: NOW - 3 * ONE_DAY });
    const result = aggregateStats({
      sessions: [old, recent],
      workspaces: [],
      rangeDays: 7,
      now: NOW,
    });
    expect(result.totals.sessions).toBe(1);
  });

  it("includes sessions exactly at the cutoff boundary", () => {
    // cutoff = NOW - 7 * ONE_DAY; session exactly at cutoff should be included (>=)
    const atCutoff = makeSession({ id: "s1", createdAt: NOW - 7 * ONE_DAY });
    const result = aggregateStats({
      sessions: [atCutoff],
      workspaces: [],
      rangeDays: 7,
      now: NOW,
    });
    expect(result.totals.sessions).toBe(1);
  });

  it("excludes sessions 1ms before cutoff", () => {
    const justBefore = makeSession({ id: "s1", createdAt: NOW - 7 * ONE_DAY - 1 });
    const result = aggregateStats({
      sessions: [justBefore],
      workspaces: [],
      rangeDays: 7,
      now: NOW,
    });
    expect(result.totals.sessions).toBe(0);
  });

  describe("daily breakdown", () => {
    it("groups sessions by UTC date", () => {
      // Two sessions on the same day, one on a different day
      const day1a = makeSession({
        id: "s1",
        createdAt: new Date("2025-06-14T03:00:00Z").getTime(),
        cost: 0.1,
      });
      const day1b = makeSession({
        id: "s2",
        createdAt: new Date("2025-06-14T23:00:00Z").getTime(),
        cost: 0.2,
      });
      const day2 = makeSession({
        id: "s3",
        createdAt: new Date("2025-06-13T12:00:00Z").getTime(),
        cost: 0.3,
      });

      const result = aggregateStats({
        sessions: [day1a, day1b, day2],
        workspaces: [],
        rangeDays: 7,
        now: NOW,
      });

      expect(result.daily).toHaveLength(2);
      // Sorted ascending by date
      expect(result.daily[0].date).toBe("2025-06-13");
      expect(result.daily[0].sessions).toBe(1);
      expect(result.daily[1].date).toBe("2025-06-14");
      expect(result.daily[1].sessions).toBe(2);
    });

    it("sorts daily entries ascending", () => {
      const sessions = [
        makeSession({ id: "s1", createdAt: new Date("2025-06-15T01:00:00Z").getTime() }),
        makeSession({ id: "s2", createdAt: new Date("2025-06-10T01:00:00Z").getTime() }),
        makeSession({ id: "s3", createdAt: new Date("2025-06-12T01:00:00Z").getTime() }),
      ];
      const result = aggregateStats({ sessions, workspaces: [], rangeDays: 7, now: NOW });
      const dates = result.daily.map((d) => d.date);
      expect(dates).toEqual([...dates].sort());
    });
  });

  describe("byModel in daily entries", () => {
    it("breaks down multiple models on the same day", () => {
      const sessions = [
        makeSession({ id: "s1", model: "claude-sonnet-4-20250514", cost: 0.1, createdAt: NOW - ONE_DAY }),
        makeSession({ id: "s2", model: "gpt-4", cost: 0.2, createdAt: NOW - ONE_DAY }),
        makeSession({ id: "s3", model: "claude-sonnet-4-20250514", cost: 0.3, createdAt: NOW - ONE_DAY }),
      ];
      const result = aggregateStats({ sessions, workspaces: [], rangeDays: 7, now: NOW });
      const day = result.daily[0];
      expect(day.byModel["claude-sonnet-4-20250514"]).toEqual({ sessions: 2, cost: 0.4, tokens: 330 });
      expect(day.byModel["gpt-4"]).toEqual({ sessions: 1, cost: 0.2, tokens: 165 });
    });
  });

  describe("model breakdown", () => {
    it("aggregates sessions per model with cache tokens", () => {
      const sessions = [
        makeSession({
          id: "s1",
          model: "claude-sonnet-4-20250514",
          cost: 0.5,
          tokens: { input: 1000, output: 500, cacheRead: 200, cacheWrite: 100 },
          createdAt: NOW - ONE_DAY,
        }),
        makeSession({
          id: "s2",
          model: "claude-sonnet-4-20250514",
          cost: 0.3,
          tokens: { input: 800, output: 400, cacheRead: 150, cacheWrite: 50 },
          createdAt: NOW - ONE_DAY,
        }),
      ];
      const result = aggregateStats({ sessions, workspaces: [], rangeDays: 7, now: NOW });
      expect(result.modelBreakdown).toHaveLength(1);
      const m = result.modelBreakdown[0];
      expect(m.model).toBe("claude-sonnet-4-20250514");
      expect(m.sessions).toBe(2);
      expect(m.cost).toBe(0.8);
      expect(m.cacheRead).toBe(350);
      expect(m.cacheWrite).toBe(150);
      expect(m.tokens).toBe(3200); // sum of all token fields
    });

    it("sorts model breakdown by cost descending", () => {
      const sessions = [
        makeSession({ id: "s1", model: "cheap", cost: 0.01, createdAt: NOW - ONE_DAY }),
        makeSession({ id: "s2", model: "expensive", cost: 10.0, createdAt: NOW - ONE_DAY }),
        makeSession({ id: "s3", model: "mid", cost: 1.0, createdAt: NOW - ONE_DAY }),
      ];
      const result = aggregateStats({ sessions, workspaces: [], rangeDays: 7, now: NOW });
      expect(result.modelBreakdown.map((m) => m.model)).toEqual(["expensive", "mid", "cheap"]);
    });

    it("computes share as fraction of total cost", () => {
      const sessions = [
        makeSession({ id: "s1", model: "a", cost: 3.0, createdAt: NOW - ONE_DAY }),
        makeSession({ id: "s2", model: "b", cost: 1.0, createdAt: NOW - ONE_DAY }),
      ];
      const result = aggregateStats({ sessions, workspaces: [], rangeDays: 7, now: NOW });
      const shareA = result.modelBreakdown.find((m) => m.model === "a")!.share;
      const shareB = result.modelBreakdown.find((m) => m.model === "b")!.share;
      expect(shareA).toBe(0.75);
      expect(shareB).toBe(0.25);
    });

    it("sets share to 0 when total cost is 0", () => {
      const sessions = [
        makeSession({ id: "s1", model: "free", cost: 0, createdAt: NOW - ONE_DAY }),
      ];
      const result = aggregateStats({ sessions, workspaces: [], rangeDays: 7, now: NOW });
      expect(result.modelBreakdown[0].share).toBe(0);
    });
  });

  describe("workspace breakdown", () => {
    it("resolves workspace names from workspace list", () => {
      const sessions = [
        makeSession({ id: "s1", workspaceId: "ws-1", createdAt: NOW - ONE_DAY }),
      ];
      const workspaces = [makeWorkspace("ws-1", "Development")];
      const result = aggregateStats({ sessions, workspaces, rangeDays: 7, now: NOW });
      expect(result.workspaceBreakdown[0].name).toBe("Development");
    });

    it("falls back to workspace ID when name not found", () => {
      const sessions = [
        makeSession({ id: "s1", workspaceId: "ws-orphan", createdAt: NOW - ONE_DAY }),
      ];
      const result = aggregateStats({ sessions, workspaces: [], rangeDays: 7, now: NOW });
      expect(result.workspaceBreakdown[0].name).toBe("ws-orphan");
      expect(result.workspaceBreakdown[0].id).toBe("ws-orphan");
    });

    it("uses 'unknown' for sessions with no workspaceId", () => {
      const sessions = [
        makeSession({ id: "s1", workspaceId: undefined, createdAt: NOW - ONE_DAY }),
      ];
      const result = aggregateStats({ sessions, workspaces: [], rangeDays: 7, now: NOW });
      expect(result.workspaceBreakdown[0].id).toBe("unknown");
    });

    it("sorts workspace breakdown by cost descending", () => {
      const sessions = [
        makeSession({ id: "s1", workspaceId: "cheap", cost: 0.01, createdAt: NOW - ONE_DAY }),
        makeSession({ id: "s2", workspaceId: "expensive", cost: 5.0, createdAt: NOW - ONE_DAY }),
      ];
      const result = aggregateStats({ sessions, workspaces: [], rangeDays: 7, now: NOW });
      expect(result.workspaceBreakdown.map((w) => w.id)).toEqual(["expensive", "cheap"]);
    });
  });

  describe("totals", () => {
    it("sums cost and tokens across all in-range sessions", () => {
      const sessions = [
        makeSession({
          id: "s1",
          cost: 1.111,
          tokens: { input: 100, output: 50, cacheRead: 0, cacheWrite: 0 },
          createdAt: NOW - ONE_DAY,
        }),
        makeSession({
          id: "s2",
          cost: 2.222,
          tokens: { input: 200, output: 100, cacheRead: 0, cacheWrite: 0 },
          createdAt: NOW - ONE_DAY,
        }),
      ];
      const result = aggregateStats({ sessions, workspaces: [], rangeDays: 7, now: NOW });
      expect(result.totals.sessions).toBe(2);
      expect(result.totals.cost).toBe(3.33); // rounded to 2 decimals
      expect(result.totals.tokens).toBe(450);
    });
  });

  describe("cost rounding", () => {
    it("rounds daily cost to 2 decimals", () => {
      const sessions = [
        makeSession({ id: "s1", cost: 0.1 + 0.2, createdAt: NOW - ONE_DAY }),
      ];
      const result = aggregateStats({ sessions, workspaces: [], rangeDays: 7, now: NOW });
      // 0.1 + 0.2 = 0.30000000000000004 in IEEE 754
      expect(result.daily[0].cost).toBe(0.3);
    });

    it("rounds total cost to 2 decimals", () => {
      const sessions = [
        makeSession({ id: "s1", cost: 0.1 + 0.2, createdAt: NOW - ONE_DAY }),
      ];
      const result = aggregateStats({ sessions, workspaces: [], rangeDays: 7, now: NOW });
      expect(result.totals.cost).toBe(0.3);
    });
  });

  // ─── Edge cases / bug bash ───

  describe("edge cases", () => {
    it("handles session with undefined tokens (no crash)", () => {
      const session = makeSession({ id: "s1", createdAt: NOW - ONE_DAY });
      // Force tokens to undefined to simulate corrupt/missing data
      (session as any).tokens = undefined;
      const result = aggregateStats({
        sessions: [session],
        workspaces: [],
        rangeDays: 7,
        now: NOW,
      });
      expect(result.totals.tokens).toBe(0);
      expect(result.totals.sessions).toBe(1);
    });

    it("handles session with null cost", () => {
      const session = makeSession({ id: "s1", createdAt: NOW - ONE_DAY });
      (session as any).cost = null;
      const result = aggregateStats({
        sessions: [session],
        workspaces: [],
        rangeDays: 7,
        now: NOW,
      });
      expect(result.totals.cost).toBe(0);
    });

    it("handles session with undefined cost", () => {
      const session = makeSession({ id: "s1", createdAt: NOW - ONE_DAY });
      (session as any).cost = undefined;
      const result = aggregateStats({
        sessions: [session],
        workspaces: [],
        rangeDays: 7,
        now: NOW,
      });
      expect(result.totals.cost).toBe(0);
    });

    it("handles session with no model (falls back to 'unknown')", () => {
      const session = makeSession({ id: "s1", model: undefined, createdAt: NOW - ONE_DAY });
      const result = aggregateStats({
        sessions: [session],
        workspaces: [],
        rangeDays: 7,
        now: NOW,
      });
      expect(result.modelBreakdown[0].model).toBe("unknown");
    });

    it("treats different model casing as separate models", () => {
      // Bug bash: "GPT-4" vs "gpt-4" — are they merged? They shouldn't be
      // (model IDs are case-sensitive in practice)
      const sessions = [
        makeSession({ id: "s1", model: "GPT-4", cost: 1.0, createdAt: NOW - ONE_DAY }),
        makeSession({ id: "s2", model: "gpt-4", cost: 2.0, createdAt: NOW - ONE_DAY }),
      ];
      const result = aggregateStats({ sessions, workspaces: [], rangeDays: 7, now: NOW });
      // Should be 2 separate entries — model names are opaque strings
      expect(result.modelBreakdown).toHaveLength(2);
    });

    it("handles createdAt of 0 (epoch start, excluded from 7-day range)", () => {
      const session = makeSession({ id: "s1", createdAt: 0 });
      const result = aggregateStats({
        sessions: [session],
        workspaces: [],
        rangeDays: 7,
        now: NOW,
      });
      expect(result.totals.sessions).toBe(0);
    });

    it("handles createdAt of 0 included in a 90-day range from epoch-near now", () => {
      // If now is close to epoch, createdAt=0 should be included
      const earlyNow = 30 * ONE_DAY; // 30 days after epoch
      const session = makeSession({ id: "s1", createdAt: 0 });
      const result = aggregateStats({
        sessions: [session],
        workspaces: [],
        rangeDays: 90,
        now: earlyNow,
      });
      expect(result.totals.sessions).toBe(1);
    });

    it("handles partial token fields (some fields present, some missing)", () => {
      const session = makeSession({ id: "s1", createdAt: NOW - ONE_DAY });
      // Only input and output, cacheRead/cacheWrite missing
      (session as any).tokens = { input: 100, output: 50 };
      const result = aggregateStats({
        sessions: [session],
        workspaces: [],
        rangeDays: 7,
        now: NOW,
      });
      // sessionTokens uses ?? 0 for each field, so partial should work
      expect(result.totals.tokens).toBe(150);
    });

    it("uses UTC dates (not local timezone)", () => {
      // A session at 2025-06-14T23:30:00Z should be on June 14 in UTC
      // regardless of local timezone
      const session = makeSession({
        id: "s1",
        createdAt: new Date("2025-06-14T23:30:00Z").getTime(),
      });
      const result = aggregateStats({
        sessions: [session],
        workspaces: [],
        rangeDays: 7,
        now: NOW,
      });
      expect(result.daily[0].date).toBe("2025-06-14");
    });
  });
});

// ─── aggregateDailyDetail ───

describe("aggregateDailyDetail", () => {
  it("returns zeroed result for empty sessions", () => {
    const result = aggregateDailyDetail([], "2025-06-14");
    expect(result.date).toBe("2025-06-14");
    expect(result.totals).toEqual({ sessions: 0, cost: 0, tokens: 0 });
    expect(result.hourly).toEqual([]);
    expect(result.sessions).toEqual([]);
  });

  it("filters sessions to the specified date", () => {
    const onDay = makeSession({
      id: "s1",
      createdAt: new Date("2025-06-14T10:00:00Z").getTime(),
    });
    const offDay = makeSession({
      id: "s2",
      createdAt: new Date("2025-06-13T10:00:00Z").getTime(),
    });
    const result = aggregateDailyDetail([onDay, offDay], "2025-06-14");
    expect(result.totals.sessions).toBe(1);
    expect(result.sessions).toHaveLength(1);
    expect(result.sessions[0].id).toBe("s1");
  });

  it("buckets sessions into correct UTC hours", () => {
    const sessions = [
      makeSession({ id: "s1", createdAt: new Date("2025-06-14T00:30:00Z").getTime() }),
      makeSession({ id: "s2", createdAt: new Date("2025-06-14T00:59:59Z").getTime() }),
      makeSession({ id: "s3", createdAt: new Date("2025-06-14T13:00:00Z").getTime() }),
    ];
    const result = aggregateDailyDetail(sessions, "2025-06-14");
    expect(result.hourly).toHaveLength(2);
    expect(result.hourly[0].hour).toBe(0);
    expect(result.hourly[0].sessions).toBe(2);
    expect(result.hourly[1].hour).toBe(13);
    expect(result.hourly[1].sessions).toBe(1);
  });

  it("includes sessions at day boundaries (00:00:00 and 23:59:59)", () => {
    const atStart = makeSession({
      id: "s1",
      createdAt: new Date("2025-06-14T00:00:00.000Z").getTime(),
    });
    const atEnd = makeSession({
      id: "s2",
      createdAt: new Date("2025-06-14T23:59:59.999Z").getTime(),
    });
    const result = aggregateDailyDetail([atStart, atEnd], "2025-06-14");
    expect(result.totals.sessions).toBe(2);
  });

  it("excludes sessions at midnight of the next day", () => {
    const nextDayMidnight = makeSession({
      id: "s1",
      createdAt: new Date("2025-06-15T00:00:00.000Z").getTime(),
    });
    const result = aggregateDailyDetail([nextDayMidnight], "2025-06-14");
    expect(result.totals.sessions).toBe(0);
  });

  it("sorts sessions by createdAt", () => {
    const later = makeSession({
      id: "later",
      createdAt: new Date("2025-06-14T15:00:00Z").getTime(),
    });
    const earlier = makeSession({
      id: "earlier",
      createdAt: new Date("2025-06-14T03:00:00Z").getTime(),
    });
    const result = aggregateDailyDetail([later, earlier], "2025-06-14");
    expect(result.sessions.map((s) => s.id)).toEqual(["earlier", "later"]);
  });

  it("sorts hourly entries by hour ascending", () => {
    const sessions = [
      makeSession({ id: "s1", createdAt: new Date("2025-06-14T23:00:00Z").getTime() }),
      makeSession({ id: "s2", createdAt: new Date("2025-06-14T01:00:00Z").getTime() }),
      makeSession({ id: "s3", createdAt: new Date("2025-06-14T12:00:00Z").getTime() }),
    ];
    const result = aggregateDailyDetail(sessions, "2025-06-14");
    const hours = result.hourly.map((h) => h.hour);
    expect(hours).toEqual([1, 12, 23]);
  });

  it("breaks down hourly entries by model", () => {
    const sessions = [
      makeSession({
        id: "s1",
        model: "claude-sonnet-4-20250514",
        cost: 0.5,
        createdAt: new Date("2025-06-14T10:00:00Z").getTime(),
      }),
      makeSession({
        id: "s2",
        model: "gpt-4",
        cost: 0.3,
        createdAt: new Date("2025-06-14T10:30:00Z").getTime(),
      }),
    ];
    const result = aggregateDailyDetail(sessions, "2025-06-14");
    expect(result.hourly).toHaveLength(1);
    const hour10 = result.hourly[0];
    expect(hour10.byModel["claude-sonnet-4-20250514"].sessions).toBe(1);
    expect(hour10.byModel["gpt-4"].sessions).toBe(1);
  });

  it("rounds costs in session list and hourly entries", () => {
    const session = makeSession({
      id: "s1",
      cost: 0.1 + 0.2, // IEEE 754: 0.30000000000000004
      createdAt: new Date("2025-06-14T10:00:00Z").getTime(),
    });
    const result = aggregateDailyDetail([session], "2025-06-14");
    expect(result.sessions[0].cost).toBe(0.3);
    expect(result.hourly[0].cost).toBe(0.3);
    expect(result.totals.cost).toBe(0.3);
  });

  it("handles undefined tokens in daily detail (no crash)", () => {
    const session = makeSession({
      id: "s1",
      createdAt: new Date("2025-06-14T10:00:00Z").getTime(),
    });
    (session as any).tokens = undefined;
    const result = aggregateDailyDetail([session], "2025-06-14");
    expect(result.sessions[0].tokens).toBe(0);
    expect(result.totals.tokens).toBe(0);
  });

  it("handles null cost in daily detail", () => {
    const session = makeSession({
      id: "s1",
      createdAt: new Date("2025-06-14T10:00:00Z").getTime(),
    });
    (session as any).cost = null;
    const result = aggregateDailyDetail([session], "2025-06-14");
    expect(result.sessions[0].cost).toBe(0);
  });

  it("maps status field through to session list", () => {
    const session = makeSession({
      id: "s1",
      status: "busy",
      createdAt: new Date("2025-06-14T10:00:00Z").getTime(),
    });
    const result = aggregateDailyDetail([session], "2025-06-14");
    expect(result.sessions[0].status).toBe("busy");
  });

  it("uses sparse hourly array (only hours with sessions)", () => {
    const session = makeSession({
      id: "s1",
      createdAt: new Date("2025-06-14T15:00:00Z").getTime(),
    });
    const result = aggregateDailyDetail([session], "2025-06-14");
    // Should only have hour 15, not 0-23
    expect(result.hourly).toHaveLength(1);
    expect(result.hourly[0].hour).toBe(15);
  });
});
