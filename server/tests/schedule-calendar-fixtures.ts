import resolvePath from "node:path";

import type { ScheduleCalendarResponse } from "../src/agent-schedule-calendar.js";
import { PROTOCOL_DIR } from "./protocol-fixtures.js";

/**
 * `protocol/schedule-calendar.json`: one `GET /schedules/calendar` answer holding every shape an
 * entry takes, so the server and the Apple client agree on the wire.
 *
 * Only this serializer defines the bytes. `schedule-calendar-fixtures.test.ts` rebuilds it in
 * memory and compares against the committed file; `npm run protocol:fixtures:update` writes it.
 * Apple `ScheduleCalendarContractTests` decodes it.
 */

export const SCHEDULE_CALENDAR_SNAPSHOT_FILE = resolvePath.join(
  PROTOCOL_DIR,
  "schedule-calendar.json",
);

export const SCHEDULE_CALENDAR_FIXTURE_DESCRIPTION =
  "One GET /schedules/calendar answer: past runs joined to their sessions (done, failed, needs you, running, a run that never started, a manual run, a prompt sent into an existing session) and upcoming occurrences (no run). Built by server/tests/schedule-calendar-fixtures.ts; server/tests/schedule-calendar-fixtures.test.ts fails when the committed bytes differ, and Apple ScheduleCalendarContractTests decodes it.";

const t = (iso: string): number => Date.parse(iso);
const zone = "America/Los_Angeles";

export function buildScheduleCalendarExample(): ScheduleCalendarResponse {
  return {
    from: t("2026-11-11T08:00:00Z"),
    to: t("2026-11-12T08:00:00Z"),
    now: t("2026-11-11T16:42:00Z"),
    schedules: [
      {
        id: "kypu0005",
        name: "Nightly Kypu sync",
        status: "active",
        trigger: { type: "cron", expression: "5 0 * * *", timeZone: zone },
        action: { type: "new_session", workspaceId: "kypu", promptChars: 212 },
        model: "anthropic/claude-sonnet-5-5",
      },
      {
        id: "night330",
        name: "Night shift",
        status: "active",
        trigger: { type: "cron", expression: "30 3 * * *", timeZone: zone },
        action: {
          type: "new_session",
          workspaceId: "oppi",
          agentId: "night-agent",
          promptChars: 840,
        },
        model: "anthropic/claude-opus-5-5",
        thinkingLevel: "high",
      },
      {
        id: "digest07",
        name: "Daily personalized HN + X digest",
        status: "active",
        trigger: { type: "cron", expression: "0 7 * * *", timeZone: zone },
        action: { type: "new_session", workspaceId: "chaosdonkey", promptChars: 1_310 },
        model: "anthropic/claude-opus-5-5",
      },
      {
        id: "jobhunt1",
        name: "Weekday job hunt",
        status: "active",
        trigger: { type: "cron", expression: "30 8 * * 1-5", timeZone: zone },
        action: { type: "new_session", workspaceId: "jobsearch", promptChars: 655 },
        model: "anthropic/claude-sonnet-5-5",
      },
      {
        id: "mirror06",
        name: "Daily upstream mirror sync",
        status: "paused",
        trigger: { type: "cron", expression: "0 6 * * *", timeZone: zone },
        action: { type: "new_session", workspaceId: "oppi", promptChars: 96 },
      },
      {
        id: "hawaii01",
        name: "Clear Hawaii no-install override",
        status: "active",
        trigger: { type: "at", at: t("2026-11-11T17:00:00Z"), timeZone: zone },
        action: {
          type: "existing_session",
          workspaceId: "oppi",
          sessionId: "sess-hawaii",
          promptChars: 120,
        },
        model: "anthropic/claude-opus-5-5",
      },
      {
        id: "nanny917",
        name: "Nanny mail triage",
        status: "active",
        trigger: { type: "cron", expression: "0 9,17 * * *", timeZone: zone },
        action: { type: "new_session", workspaceId: "nanny", promptChars: 402 },
        model: "anthropic/claude-sonnet-5-5",
      },
      {
        id: "pulse015",
        name: "Queue pulse",
        status: "active",
        trigger: { type: "every", intervalMs: 300_000, timeZone: zone },
        action: { type: "new_session", workspaceId: "oppi", promptChars: 40 },
        upcomingTruncated: true,
      },
    ],
    entries: [
      {
        scheduleId: "kypu0005",
        slotKey: `cron:${t("2026-11-11T08:05:00Z")}`,
        at: t("2026-11-11T08:05:00Z"),
        run: {
          id: "run-kypu",
          kind: "due",
          status: "completed",
          createdAt: t("2026-11-11T08:05:01Z"),
          startedAt: t("2026-11-11T08:05:02Z"),
          completedAt: t("2026-11-11T08:05:04Z"),
          promptDispatch: "delivered",
          session: {
            id: "sess-kypu",
            workspaceId: "kypu",
            status: "stopped",
            programStatus: { state: "done", since: t("2026-11-11T08:07:40Z") },
            cost: 0.42,
            model: "anthropic/claude-sonnet-5-5",
            settledAt: t("2026-11-11T08:07:40Z"),
          },
        },
      },
      {
        scheduleId: "night330",
        slotKey: `cron:${t("2026-11-11T11:30:00Z")}`,
        at: t("2026-11-11T11:30:00Z"),
        run: {
          id: "run-night",
          kind: "due",
          status: "completed",
          createdAt: t("2026-11-11T11:30:01Z"),
          startedAt: t("2026-11-11T11:30:02Z"),
          completedAt: t("2026-11-11T11:30:05Z"),
          promptDispatch: "delivered",
          session: {
            id: "sess-night",
            workspaceId: "oppi",
            status: "busy",
            programStatus: { state: "working", since: t("2026-11-11T16:40:00Z") },
            cost: 4.88,
            model: "anthropic/claude-opus-5-5",
          },
        },
      },
      {
        scheduleId: "mirror06",
        slotKey: `cron:${t("2026-11-11T14:00:00Z")}`,
        at: t("2026-11-11T14:00:00Z"),
        run: {
          id: "run-mirror",
          kind: "due",
          status: "failed",
          createdAt: t("2026-11-11T14:00:01Z"),
          startedAt: t("2026-11-11T14:00:02Z"),
          completedAt: t("2026-11-11T14:00:02Z"),
          error: "approval_required_noninteractive: bash git push",
        },
      },
      {
        scheduleId: "digest07",
        slotKey: `cron:${t("2026-11-11T15:00:00Z")}`,
        at: t("2026-11-11T15:00:00Z"),
        run: {
          id: "run-digest",
          kind: "due",
          status: "completed",
          createdAt: t("2026-11-11T15:00:01Z"),
          startedAt: t("2026-11-11T15:00:02Z"),
          completedAt: t("2026-11-11T15:00:04Z"),
          promptDispatch: "delivered",
          session: {
            id: "sess-digest",
            workspaceId: "chaosdonkey",
            status: "stopped",
            programStatus: {
              state: "error",
              message: "Provider returned 529",
              since: t("2026-11-11T15:05:10Z"),
            },
            cost: 1.65,
            model: "anthropic/claude-opus-5-5",
            settledAt: t("2026-11-11T15:05:10Z"),
          },
        },
      },
      {
        scheduleId: "jobhunt1",
        slotKey: `cron:${t("2026-11-11T16:30:00Z")}`,
        at: t("2026-11-11T16:30:00Z"),
        run: {
          id: "run-jobs",
          kind: "due",
          status: "completed",
          createdAt: t("2026-11-11T16:30:01Z"),
          startedAt: t("2026-11-11T16:30:02Z"),
          completedAt: t("2026-11-11T16:30:04Z"),
          promptDispatch: "delivered",
          session: {
            id: "sess-jobs",
            workspaceId: "jobsearch",
            status: "ready",
            programStatus: {
              state: "blocked",
              kind: "question",
              message: "Apply to these three?",
              since: t("2026-11-11T16:34:00Z"),
            },
            cost: 0.58,
            model: "anthropic/claude-sonnet-5-5",
          },
        },
      },
      {
        scheduleId: "nanny917",
        slotKey: "manual:req-7f3a",
        at: t("2026-11-11T16:40:00Z"),
        run: {
          id: "run-nanny-manual",
          kind: "manual",
          status: "pending",
          createdAt: t("2026-11-11T16:40:00Z"),
        },
      },
      {
        scheduleId: "hawaii01",
        slotKey: `at:${t("2026-11-11T17:00:00Z")}`,
        at: t("2026-11-11T17:00:00Z"),
      },
      {
        scheduleId: "nanny917",
        slotKey: `cron:${t("2026-11-11T17:00:00Z")}`,
        at: t("2026-11-11T17:00:00Z"),
      },
      {
        scheduleId: "nanny917",
        slotKey: `cron:${t("2026-11-12T01:00:00Z")}`,
        at: t("2026-11-12T01:00:00Z"),
      },
    ],
  };
}

export function serializeScheduleCalendarFixture(): string {
  return (
    JSON.stringify(
      {
        _meta: {
          description: SCHEDULE_CALENDAR_FIXTURE_DESCRIPTION,
          source: "server/src/agent-schedule-calendar.ts",
        },
        body: buildScheduleCalendarExample(),
      },
      null,
      2,
    ) + "\n"
  );
}
