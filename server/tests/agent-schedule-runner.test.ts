import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { AgentScheduleRunner, dueSlotKeysForSchedule } from "../src/agent-schedule-runner.js";
import { AgentScheduleStore } from "../src/agent-schedules.js";
import type { AgentScheduleAction } from "../src/agent-schedules.js";
import type { Session, Workspace } from "../src/types.js";

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "sess-1",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    runtime: "oppi",
    ...overrides,
  };
}

describe("agent schedule runner", () => {
  let dataDir: string;
  let store: AgentScheduleStore;
  let sessions: Session[];
  let startSession: ReturnType<typeof vi.fn>;
  let sendPrompt: ReturnType<typeof vi.fn>;
  const workspace: Workspace = { id: "ws-1", name: "Workspace" } as Workspace;

  beforeEach(() => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-schedule-runner-"));
    store = new AgentScheduleStore(dataDir);
    sessions = [];
    startSession = vi.fn(async (sessionId: string) => makeSession({ id: sessionId }));
    sendPrompt = vi.fn(async () => undefined);
  });

  afterEach(() => {
    store.close();
    rmSync(dataDir, { recursive: true, force: true });
  });

  function storage() {
    return {
      getAgentScheduleStore: () => store,
      getWorkspace: vi.fn((workspaceId: string) =>
        workspaceId === workspace.id ? workspace : undefined,
      ),
      getSession: vi.fn((sessionId: string) =>
        sessions.find((session) => session.id === sessionId),
      ),
      createSession: vi.fn((name?: string, model?: string) => {
        const session = makeSession({ id: `sess-${sessions.length + 1}`, name, model });
        sessions.push(session);
        return session;
      }),
      saveSession: vi.fn((session: Session) => {
        const index = sessions.findIndex((candidate) => candidate.id === session.id);
        if (index >= 0) sessions[index] = session;
        else sessions.push(session);
      }),
      listSessions: vi.fn(() => sessions),
      findSessionByLaunchIdempotencyKey: vi.fn((key: string) =>
        sessions.find((session) => session.launch?.idempotencyKey === key),
      ),
      claimSessionLaunchRecovery: vi.fn(() => undefined),
    };
  }

  function recordAcceptedApprovalEvent(input: {
    approvalRefId: string;
    scheduleId: string;
    workspaceId?: string;
  }): void {
    Reflect.get(store, "db")
      .prepare(
        `INSERT INTO server_agent_extension_audit_events (
           id, created_at, workspace_id, schedule_id, event_type, approval_ref_id, envelope_json
         ) VALUES (?, ?, ?, ?, 'approval_ref.accepted', ?, ?)`,
      )
      .run(
        `audit:${input.approvalRefId}:${input.scheduleId}`,
        1,
        input.workspaceId ?? "ws-1",
        input.scheduleId,
        input.approvalRefId,
        JSON.stringify({ eventType: "approval_ref.accepted", approvalRefId: input.approvalRefId }),
      );
  }

  function action(prompt = "Run the checks"): AgentScheduleAction {
    return {
      type: "new_session",
      workspaceId: workspace.id,
      prompt,
      name: "Scheduled check",
      approvalRefs: ["approval://schedule"],
    };
  }

  it("materializes and dispatches an at schedule once", async () => {
    const schedule = store.createSchedule(
      {
        name: "Morning check",
        trigger: { type: "at", at: 1_000, timeZone: "UTC" },
        action: action(),
      },
      500,
    );
    recordAcceptedApprovalEvent({ approvalRefId: "approval://schedule", scheduleId: schedule.id });
    const runner = new AgentScheduleRunner({
      storage: storage(),
      sessions: { startSession, sendPrompt },
      ensureSessionContextWindow: (session) => session,
      nowMs: () => 2_000,
    });

    await runner.runOnce();
    await runner.runOnce();

    expect(startSession).toHaveBeenCalledTimes(1);
    expect(sendPrompt).toHaveBeenCalledTimes(1);
    expect(store.listRunSummaries(schedule.id)).toEqual([
      expect.objectContaining({
        status: "completed",
        slotKey: "at:1000",
        sessionId: sessions[0]?.id,
      }),
    ]);
    expect(sessions[0]?.launch?.source).toBe("schedule");
    expect(sessions[0]?.launch?.schedule).toMatchObject({ scheduleId: schedule.id });
  });

  it("does not let the automatic runner claim manual runs", async () => {
    const schedule = store.createSchedule(
      {
        name: "Manual check",
        trigger: { type: "at", at: 1_000, timeZone: "UTC" },
        action: action(),
      },
      500,
    );
    recordAcceptedApprovalEvent({ approvalRefId: "approval://schedule", scheduleId: schedule.id });
    store.createManualRun(schedule.id, "human-button", 1_000);
    const runner = new AgentScheduleRunner({
      storage: storage(),
      sessions: { startSession, sendPrompt },
      ensureSessionContextWindow: (session) => session,
      nowMs: () => 900,
    });

    await runner.runOnce();

    expect(startSession).not.toHaveBeenCalled();
    expect(store.listRunSummaries(schedule.id)).toEqual([
      expect.objectContaining({ kind: "manual", status: "pending" }),
    ]);
  });

  it("matches daily cron schedules in their configured time zone", () => {
    const schedule = store.createSchedule(
      {
        name: "Daily review",
        trigger: {
          type: "cron",
          expression: "0 7 * * *",
          timeZone: "America/Los_Angeles",
        },
        action: action(),
      },
      Date.parse("2026-06-28T00:00:00Z"),
    );
    const dueNow = Date.parse("2026-06-29T14:00:30Z");
    const notDue = Date.parse("2026-06-29T13:59:30Z");

    expect(dueSlotKeysForSchedule(schedule, dueNow)).toEqual([
      `cron:${Date.parse("2026-06-29T14:00:00Z")}`,
    ]);
    expect(dueSlotKeysForSchedule(schedule, notDue)).toEqual([]);
  });

  it("does not materialize the current cron minute when created after the slot started", () => {
    const slotStart = Date.parse("2026-06-29T14:00:00Z");
    const schedule = store.createSchedule(
      {
        name: "Daily review",
        trigger: {
          type: "cron",
          expression: "0 7 * * *",
          timeZone: "America/Los_Angeles",
        },
        action: action(),
      },
      slotStart + 30_000,
    );

    expect(dueSlotKeysForSchedule(schedule, slotStart + 45_000)).toEqual([]);
  });

  it("waits one interval before the first every run", () => {
    const schedule = store.createSchedule(
      {
        name: "Every hour",
        trigger: { type: "every", intervalMs: 3_600_000, timeZone: "UTC" },
        action: action(),
      },
      1_000,
    );

    expect(dueSlotKeysForSchedule(schedule, 1_000)).toEqual([]);
    expect(dueSlotKeysForSchedule(schedule, 3_601_000)).toEqual(["every:3601000"]);
  });
});
