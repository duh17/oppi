import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import {
  SCHEDULE_CALENDAR_SNAPSHOT_FILE,
  serializeScheduleCalendarFixture,
} from "./schedule-calendar-fixtures.js";

describe("schedule calendar protocol fixture", () => {
  it("matches the committed protocol/schedule-calendar.json", () => {
    // Never writes: a deliberate regeneration runs `npm run protocol:fixtures:update`.
    expect(serializeScheduleCalendarFixture()).toBe(
      readFileSync(SCHEDULE_CALENDAR_SNAPSHOT_FILE, "utf8"),
    );
  });
});
