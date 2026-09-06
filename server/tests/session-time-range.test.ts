import { afterEach, describe, expect, it, vi } from "vitest";

import { parseSessionTimeRange } from "../src/session-time-range.js";

describe("session time range parsing", () => {
  afterEach(() => {
    vi.useRealTimers();
  });
  it("accepts epoch milliseconds and ISO timestamps with inclusive boundaries", () => {
    expect(
      parseSessionTimeRange("1700000000000", "2026-07-02T12:30:00.000Z", "session list"),
    ).toEqual({
      sinceMs: 1_700_000_000_000,
      untilMs: Date.parse("2026-07-02T12:30:00.000Z"),
    });
  });

  it("uses local-calendar starts and includes the whole until day", () => {
    expect(parseSessionTimeRange("2026-07-01", "2026-07-02", "session list")).toEqual({
      sinceMs: new Date(2026, 6, 1, 0, 0, 0, 0).getTime(),
      untilMs: new Date(2026, 6, 3, 0, 0, 0, 0).getTime() - 1,
    });
  });

  it.each([
    ["20m", 20 * 60_000],
    ["36h", 36 * 3_600_000],
    ["2d", 2 * 86_400_000],
    ["45d", 45 * 86_400_000],
  ] as const)("treats %s as now minus that duration", (raw, ageMs) => {
    const now = 1_700_000_000_000;
    vi.useFakeTimers();
    vi.setSystemTime(now);
    expect(parseSessionTimeRange(raw, undefined, "session search")).toEqual({
      sinceMs: now - ageMs,
    });
    expect(parseSessionTimeRange(undefined, raw, "session search")).toEqual({
      untilMs: now - ageMs,
    });
  });

  it("keeps bare digits as epoch milliseconds, not a duration in seconds", () => {
    expect(parseSessionTimeRange("3000", undefined, "session list")).toEqual({
      sinceMs: 3000,
    });
  });

  it.each([
    ["2026-02-30", undefined, "invalid session list date: 2026-02-30"],
    ["not-a-date", undefined, "invalid session list timestamp: not-a-date"],
    ["3000", "2000", "session list since must be before or equal to until"],
  ])("rejects invalid range %s..%s", (since, until, error) => {
    expect(parseSessionTimeRange(since, until, "session list")).toEqual({ error });
  });

  it("preserves session search error wording", () => {
    expect(parseSessionTimeRange("3000", "2000", "session search")).toEqual({
      error: "since must be before or equal to until",
    });
  });
});
