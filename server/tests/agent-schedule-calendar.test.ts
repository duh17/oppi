import { afterEach, beforeEach, describe, expect, it } from "vitest";

import {
  SCHEDULE_CALENDAR_UPCOMING_LIMIT,
  buildScheduleCalendar,
  parseScheduleCalendarRange,
  type ScheduleCalendarSources,
} from "../src/agent-schedule-calendar.js";
import { cronOccurrences } from "../src/agent-schedule-cron.js";
import { dueSlotKeysForSchedule } from "../src/agent-schedule-runner.js";
import { AgentScheduleStore, type AgentSchedule } from "../src/agent-schedules.js";
import type { Session } from "../src/types.js";
import { makeTempDir } from "./harness/temp-dir.js";

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

/** The runner's own answer, one minute at a time: the rule the calendar must match. */
function minuteWalk(schedule: AgentSchedule, from: number, to: number): number[] {
  const due: number[] = [];
  for (let minute = Math.ceil(from / 60_000) * 60_000; minute < to; minute += 60_000) {
    for (const slot of dueSlotKeysForSchedule(schedule, minute)) due.push(Number(slot.slice(5)));
  }
  return due;
}

/** Deterministic, so a failure names the case that broke. */
function seededRandom(seed: number): () => number {
  let state = seed;
  return () => {
    state = (state * 1_103_515_245 + 12_345) % 2_147_483_648;
    return state / 2_147_483_648;
  };
}

function session(overrides: Partial<Session> & { id: string }): Session {
  return {
    status: "stopped",
    createdAt: 0,
    lastActivity: 0,
    messageCount: 1,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

describe("schedule calendar", () => {
  let store: AgentScheduleStore;
  let sessions: Map<string, Session>;
  let sources: ScheduleCalendarSources;

  beforeEach(() => {
    store = new AgentScheduleStore(makeTempDir("oppi-schedule-calendar-"));
    sessions = new Map();
    sources = {
      listSchedules: () => store.listSchedules(),
      listRunsCreatedBetween: (from, to) => store.listRunsCreatedBetween(from, to),
      getSession: (id) => sessions.get(id),
      listChildSessions: (id) =>
        [...sessions.values()].filter((candidate) => candidate.launch?.parentSessionId === id),
      agentDefaultModel: (agentId) => (agentId === "agent-1" ? "anthropic/agent-model" : undefined),
    };
  });

  afterEach(() => store.close());

  function cron(expression: string, timeZone: string, createdAt: number, name = expression) {
    return store.createSchedule(
      {
        name,
        trigger: { type: "cron", expression, timeZone },
        action: { type: "new_session", workspaceId: "ws-1", prompt: "go" },
      },
      createdAt,
    );
  }

  /** Dispatches a due run that launched `sessionId`. */
  async function completeRun(scheduleId: string, slotKey: string, at: number, sessionId: string) {
    store.createDueRun(scheduleId, slotKey, at);
    const [claimed] = store.claimReadyRuns({ now: at, ownerId: "t", leaseMs: 60_000, limit: 1 });
    if (!claimed) throw new Error("no run to claim");
    return store.dispatchClaimedRun(
      claimed.id,
      {
        launchNewSession: async () => ({ sessionId, promptDispatch: "delivered" }),
        sendExistingSessionInput: async () => ({ sessionId, promptDispatch: "delivered" }),
      },
      { leaseOwner: "t", now: at },
    );
  }

  describe("cron occurrences", () => {
    // Each zone's change week: US spring and fall, Lord Howe's 30-minute shift, and a
    // zone that never changes. One test per week: the runner's walk evaluates every minute of
    // four days for each expression (about 46,000 evaluations a week), so one week is one
    // test's worth of CPU work, and a failure names its zone.
    it.each([
      ["America/Los_Angeles", "2026-03-05T00:00:00Z", 7],
      ["America/Los_Angeles", "2026-10-29T00:00:00Z", 8],
      ["America/New_York", "2026-10-29T00:00:00Z", 9],
      ["Australia/Lord_Howe", "2026-04-02T00:00:00Z", 10],
      ["Asia/Kolkata", "2026-03-05T00:00:00Z", 11],
    ])("agree with the runner's minute-by-minute walk in %s from %s", (timeZone, weekStart, seed) => {
      const random = seededRandom(seed);
      const expressions = [
        "30 1 * * *",
        "30 2 * * *",
        "0,30 0-3 * * *",
        "*/20 1-2 * * *",
        "15 9 * * 1-5",
        "45 23 * * 0",
        "0 6 1,15 * 1",
        "5 0 * * *",
      ];
      for (const expression of expressions) {
        const from = Date.parse(weekStart) + Math.floor(random() * 12) * HOUR;
        const to = from + 4 * DAY;
        // Sometimes created inside the range, so the repeated-hour rule's `createdAt`
        // branch is exercised too.
        const createdAt = from - DAY + Math.floor(random() * 3 * DAY);
        const schedule = cron(expression, timeZone, createdAt);
        const expected = minuteWalk(schedule, from, to);
        const { at, truncated } = cronOccurrences(expression, timeZone, {
          from,
          to,
          createdAt,
          limit: 10_000,
        });
        expect({ expression, at }).toEqual({ expression, at: expected });
        expect(truncated).toBe(false);
      }
    });

    it("skip a spring-forward gap and list a fall-back hour once", () => {
      const createdAt = Date.parse("2026-03-01T00:00:00Z");
      // 2026-03-08: 02:00 PST jumps to 03:00 PDT, so 02:30 never happens.
      const spring = cronOccurrences("30 2 * * *", "America/Los_Angeles", {
        from: Date.parse("2026-03-07T12:00:00Z"),
        to: Date.parse("2026-03-10T12:00:00Z"),
        createdAt,
        limit: 10,
      }).at;
      expect(spring).toEqual([
        Date.parse("2026-03-09T09:30:00Z"), // Mar 9, 02:30 PDT
        Date.parse("2026-03-10T09:30:00Z"), // Mar 10, 02:30 PDT
      ]);

      // 2026-11-01: 01:30 happens at 08:30Z (PDT) and again at 09:30Z (PST); only the first runs.
      const fall = cronOccurrences("30 1 * * *", "America/Los_Angeles", {
        from: Date.parse("2026-11-01T00:00:00Z"),
        to: Date.parse("2026-11-02T00:00:00Z"),
        createdAt,
        limit: 10,
      }).at;
      expect(fall).toEqual([Date.parse("2026-11-01T08:30:00Z")]);
    });

    it("stop at the limit and say so", () => {
      const result = cronOccurrences("* * * * *", "UTC", {
        from: 0,
        to: DAY,
        createdAt: 0,
        limit: 5,
      });
      expect(result).toEqual({ at: [0, 60_000, 120_000, 180_000, 240_000], truncated: true });
    });
  });

  describe("range", () => {
    it("takes epoch milliseconds up to 62 days", () => {
      const url = (query: string) => new URL(`https://localhost/schedules/calendar?${query}`);
      expect(parseScheduleCalendarRange(url("from=10&to=20"))).toEqual({ from: 10, to: 20 });
      expect(() => parseScheduleCalendarRange(url("from=20&to=10"))).toThrow("after");
      expect(() => parseScheduleCalendarRange(url(`from=0&to=${63 * DAY}`))).toThrow("62 days");
      expect(() => parseScheduleCalendarRange(url("from=yesterday&to=20"))).toThrow("epoch");
      expect(() => parseScheduleCalendarRange(url("to=20"))).toThrow("from");
    });
  });

  it("lists a range spanning midnight with each run on its own side of it", () => {
    const zone = "America/Los_Angeles";
    const created = Date.parse("2026-11-01T00:00:00Z");
    const late = cron("0 23 * * *", zone, created, "Late");
    const early = cron("5 0 * * *", zone, created, "Early");
    // Nov 10, 10 PM to Nov 11, 2 AM, Pacific (UTC-8).
    const from = Date.parse("2026-11-11T06:00:00Z");
    const to = Date.parse("2026-11-11T10:00:00Z");

    const calendar = buildScheduleCalendar(sources, { from, to, now: from });

    expect(calendar.entries).toEqual([
      {
        scheduleId: late.id,
        slotKey: `cron:${Date.parse("2026-11-11T07:00:00Z")}`,
        at: Date.parse("2026-11-11T07:00:00Z"),
      },
      {
        scheduleId: early.id,
        slotKey: `cron:${Date.parse("2026-11-11T08:05:00Z")}`,
        at: Date.parse("2026-11-11T08:05:00Z"),
      },
    ]);
  });

  it("joins past runs to their sessions' outcome, cost, and model, and lists only what is still to come", async () => {
    const zone = "UTC";
    const digest = cron("0 7 * * *", zone, 0, "Digest");
    const ranAt = Date.parse("2026-11-11T07:00:00Z");
    await completeRun(digest.id, `cron:${ranAt}`, ranAt, "sess-digest");
    sessions.set(
      "sess-digest",
      session({
        id: "sess-digest",
        workspaceId: "ws-1",
        cost: 1.65,
        model: "anthropic/claude-opus-5-5",
        programStatus: { state: "error", message: "boom", since: ranAt + 5 * 60_000 },
      }),
    );
    const from = Date.parse("2026-11-11T00:00:00Z");
    const now = Date.parse("2026-11-11T08:42:00Z");

    const calendar = buildScheduleCalendar(sources, { from, to: from + DAY, now });

    expect(calendar.entries).toEqual([
      {
        scheduleId: digest.id,
        slotKey: `cron:${ranAt}`,
        at: ranAt,
        run: expect.objectContaining({
          status: "completed",
          kind: "due",
          promptDispatch: "delivered",
          session: {
            id: "sess-digest",
            workspaceId: "ws-1",
            status: "stopped",
            programStatus: { state: "error", message: "boom", since: ranAt + 5 * 60_000 },
            cost: 1.65,
            model: "anthropic/claude-opus-5-5",
            settledAt: ranAt + 5 * 60_000,
          },
        }),
      },
    ]);
    // Today's 7:00 is past and taken by its run; tomorrow's is outside the range.
    expect(calendar.schedules).toEqual([
      expect.objectContaining({ id: digest.id, name: "Digest", status: "active" }),
    ]);
  });

  describe("descendants", () => {
    const ranAt = Date.parse("2026-11-11T03:30:00Z");
    const from = Date.parse("2026-11-11T00:00:00Z");

    function child(id: string, parent: string, createdAt: number, extra: Partial<Session> = {}) {
      sessions.set(
        id,
        session({ id, createdAt, cost: 1, launch: { parentSessionId: parent }, ...extra }),
      );
    }

    function runSession(calendar: ReturnType<typeof buildScheduleCalendar>, runSessionId: string) {
      return calendar.entries.find((entry) => entry.run?.session?.id === runSessionId)?.run
        ?.session;
    }

    it("lists children and grandchildren oldest first, as list rows, beside the session's own cost", async () => {
      const nightly = cron("30 3 * * *", "UTC", 0, "Night shift");
      await completeRun(nightly.id, `cron:${ranAt}`, ranAt, "sess-night");
      sessions.set("sess-night", session({ id: "sess-night", cost: 13.22 }));
      child("kid-b", "sess-night", ranAt + 2_000, {
        cost: 2.5,
        launch: { parentSessionId: "sess-night", agentId: "reviewer" },
      });
      child("kid-a", "sess-night", ranAt + 1_000);
      child("grandkid", "kid-a", ranAt + 3_000);
      child("stranger", "someone-else", ranAt + 4_000);

      const night = runSession(
        buildScheduleCalendar(sources, { from, to: from + DAY, now: from + 8 * HOUR }),
        "sess-night",
      );

      expect(night?.cost).toBe(13.22);
      expect(night?.descendants?.map((summary) => summary.id)).toEqual([
        "kid-a",
        "kid-b",
        "grandkid",
      ]);
      expect(night?.descendants?.[1]).toMatchObject({
        id: "kid-b",
        cost: 2.5,
        agentId: "reviewer",
        parentSessionId: "sess-night",
      });
    });

    it("leaves out a descendant that is another run's session, with everything under it", async () => {
      const nightly = cron("30 3 * * *", "UTC", 0, "Night shift");
      await completeRun(nightly.id, `cron:${ranAt}`, ranAt, "sess-night");
      sessions.set("sess-night", session({ id: "sess-night", cost: 5 }));
      child("kid", "sess-night", ranAt + 1_000);
      child("scheduled-kid", "sess-night", ranAt + 2_000, {
        launch: {
          parentSessionId: "sess-night",
          schedule: { scheduleId: "other", runId: "run-other", slotKey: "manual:x" },
        },
      });
      child("under-scheduled", "scheduled-kid", ranAt + 3_000);

      const night = runSession(
        buildScheduleCalendar(sources, { from, to: from + DAY, now: from + 8 * HOUR }),
        "sess-night",
      );

      expect(night?.descendants?.map((summary) => summary.id)).toEqual(["kid"]);
    });

    it("lists each descendant once through a parent cycle, and none for a session without children", async () => {
      const nightly = cron("30 3 * * *", "UTC", 0, "Night shift");
      await completeRun(nightly.id, `cron:${ranAt}`, ranAt, "sess-night");
      sessions.set("sess-night", session({ id: "sess-night" }));
      child("loop-a", "sess-night", ranAt + 1_000);
      child("loop-b", "loop-a", ranAt + 2_000);
      // A broken record pointing back up the tree.
      sessions.set(
        "sess-night",
        session({ id: "sess-night", launch: { parentSessionId: "loop-b" } }),
      );
      const digest = cron("0 7 * * *", "UTC", 0, "Digest");
      const digestAt = Date.parse("2026-11-11T07:00:00Z");
      await completeRun(digest.id, `cron:${digestAt}`, digestAt, "sess-digest");
      sessions.set("sess-digest", session({ id: "sess-digest" }));

      const calendar = buildScheduleCalendar(sources, { from, to: from + DAY, now: from + 8 * HOUR });

      expect(runSession(calendar, "sess-night")?.descendants?.map((summary) => summary.id)).toEqual([
        "loop-a",
        "loop-b",
      ]);
      expect(runSession(calendar, "sess-digest")).not.toHaveProperty("descendants");
    });

    it("gives a run sent into an existing session none of that session's children", async () => {
      const target = store.createSchedule(
        {
          name: "Nudge",
          trigger: { type: "cron", expression: "30 3 * * *", timeZone: "UTC" },
          action: {
            type: "existing_session",
            workspaceId: "ws-1",
            sessionId: "sess-long",
            prompt: "go on",
          },
        },
        0,
      );
      await completeRun(target.id, `cron:${ranAt}`, ranAt, "sess-long");
      sessions.set("sess-long", session({ id: "sess-long" }));
      child("old-kid", "sess-long", ranAt - DAY);

      const long = runSession(
        buildScheduleCalendar(sources, { from, to: from + DAY, now: from + 8 * HOUR }),
        "sess-long",
      );

      expect(long).toBeDefined();
      expect(long).not.toHaveProperty("descendants");
    });
  });

  it("keeps a slot that just came due until the runner records its run, then lists the run once", async () => {
    const digest = cron("0 7 * * *", "UTC", 0, "Digest");
    const from = Date.parse("2026-11-11T00:00:00Z");
    const due = Date.parse("2026-11-11T07:00:00Z");
    const range = { from, to: from + DAY };
    const listed = (now: number) =>
      buildScheduleCalendar(sources, { ...range, now }).entries.map((entry) => [
        entry.at,
        entry.run !== undefined,
      ]);

    // The runner ticks on its own interval: at 7:00:20 it has not seen the minute yet.
    expect(listed(due + 20_000)).toEqual([[due, false]]);
    // Still inside the runner's catch-up window, so the run can still be recorded.
    expect(listed(due + 5 * 60_000)).toEqual([[due, false]]);
    // Past the window the runner will not record it: not shown, as before.
    expect(listed(due + 5 * 60_000 + 1)).toEqual([]);

    await completeRun(digest.id, `cron:${due}`, due + 40_000, "sess-digest");
    expect(listed(due + 60_000)).toEqual([[due, true]]);
  });

  it("lists only the latest of several slots already due, as the runner records only that one", () => {
    cron("* * * * *", "UTC", 0, "Every minute");
    const from = Date.parse("2026-11-11T00:00:00Z");
    const now = from + 7 * HOUR + 30_000;

    const calendar = buildScheduleCalendar(sources, { from, to: now + 2 * 60_000, now });

    expect(calendar.entries.map((entry) => entry.at - from - 7 * HOUR)).toEqual([
      0,
      60_000,
      120_000,
    ]);
  });

  it("keeps a paused schedule's runs and lists no upcoming ones for it", async () => {
    const nightly = cron("30 3 * * *", "UTC", 0, "Night shift");
    const ranAt = Date.parse("2026-11-11T03:30:00Z");
    await completeRun(nightly.id, `cron:${ranAt}`, ranAt, "sess-night");
    store.pauseSchedule(nightly.id);
    const from = Date.parse("2026-11-11T00:00:00Z");

    const calendar = buildScheduleCalendar(sources, {
      from,
      to: from + 3 * DAY,
      now: from + 8 * HOUR,
    });

    expect(calendar.entries.map((entry) => [entry.at, entry.run?.id !== undefined])).toEqual([
      [ranAt, true],
    ]);
    expect(calendar.schedules).toEqual([expect.objectContaining({ status: "paused" })]);
  });

  it("lists a one-shot once before it runs, and only its run after", async () => {
    const at = Date.parse("2026-11-11T09:00:00Z");
    const once = store.createSchedule(
      {
        name: "Clear override",
        trigger: { type: "at", at, timeZone: "UTC" },
        action: { type: "new_session", workspaceId: "ws-1", prompt: "go", agentId: "agent-1" },
      },
      Date.parse("2026-11-10T00:00:00Z"),
    );
    const from = Date.parse("2026-11-11T00:00:00Z");

    const before = buildScheduleCalendar(sources, { from, to: from + 2 * DAY, now: at - HOUR });
    expect(before.entries).toEqual([{ scheduleId: once.id, slotKey: `at:${at}`, at }]);
    // Agent-based: the model is the Agent's default, as dispatch would pick it.
    expect(before.schedules).toEqual([
      expect.objectContaining({ id: once.id, model: "anthropic/agent-model" }),
    ]);

    await completeRun(once.id, `at:${at}`, at, "sess-once");
    const after = buildScheduleCalendar(sources, { from, to: from + 2 * DAY, now: at + HOUR });
    expect(after.entries).toEqual([
      expect.objectContaining({
        slotKey: `at:${at}`,
        at,
        run: expect.objectContaining({ status: "completed" }),
      }),
    ]);
    // The delivered one-shot archived itself, and stays named for its run.
    expect(after.schedules).toEqual([expect.objectContaining({ status: "archived" })]);
  });

  it("caps a dense schedule's upcoming occurrences and flags the cap", () => {
    store.createSchedule(
      {
        name: "Every minute",
        trigger: { type: "every", intervalMs: 60_000, timeZone: "UTC" },
        action: { type: "new_session", workspaceId: "ws-1", prompt: "go" },
      },
      0,
    );

    const calendar = buildScheduleCalendar(sources, { from: 0, to: DAY, now: 0 });

    expect(calendar.entries).toHaveLength(SCHEDULE_CALENDAR_UPCOMING_LIMIT);
    expect(calendar.entries[0]?.at).toBe(60_000);
    expect(calendar.schedules).toEqual([expect.objectContaining({ upcomingTruncated: true })]);
  });
});
