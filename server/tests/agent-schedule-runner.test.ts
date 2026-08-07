import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createAgentScheduleDispatchHooks } from "../src/agent-schedule-dispatch.js";
import { AgentScheduleRunner, dueSlotKeysForSchedule } from "../src/agent-schedule-runner.js";
import type { AgentDefinition } from "../src/agent-launch-service.js";
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

  function storage(
    resolvedAgent?: {
      id: string;
      version: number;
      status: "active";
      definition: AgentDefinition;
    },
  ) {
    return {
      getAgentScheduleStore: () => store,
      getWorkspace: vi.fn((workspaceId: string) =>
        workspaceId === workspace.id ? workspace : undefined,
      ),
      getDataDir: vi.fn(() => dataDir),
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
      deleteSession: vi.fn((sessionId: string) => {
        const index = sessions.findIndex((session) => session.id === sessionId);
        if (index < 0) return false;
        sessions.splice(index, 1);
        return true;
      }),
      listSessions: vi.fn(() => sessions),
      findSessionByLaunchIdempotencyKey: vi.fn((key: string) =>
        sessions.find((session) => session.launch?.idempotencyKey === key),
      ),
      claimSessionLaunchRecovery: vi.fn(() => undefined),
      getAgentDefinitionStore: vi.fn(() => ({
        resolveAgent: vi.fn(() => resolvedAgent),
      })),
    };
  }

  function action(prompt = "Run the checks"): AgentScheduleAction {
    return {
      type: "new_session",
      workspaceId: workspace.id,
      prompt,
      name: "Scheduled check",
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
    expect(sessions[0]?.launch?.modelPolicy).toBeUndefined();
  });

  it("applies a schedule thinking override to the launched session", async () => {
    const schedule = store.createSchedule(
      {
        name: "Deep thinking check",
        trigger: { type: "at", at: 1_000, timeZone: "UTC" },
        action: { ...action(), thinkingLevel: "high" },
      },
      500,
    );
    const runner = new AgentScheduleRunner({
      storage: storage(),
      sessions: { startSession, sendPrompt },
      ensureSessionContextWindow: (session) => session,
      nowMs: () => 2_000,
    });

    await runner.runOnce();

    expect(store.listRunSummaries(schedule.id)).toEqual([
      expect.objectContaining({ status: "completed" }),
    ]);
    expect(sessions[0]).toMatchObject({
      thinkingLevel: "high",
      launch: { thinkingLevel: "high" },
    });
  });

  it("marks explicitly modeled schedule launches as fail-closed", async () => {
    const schedule = store.createSchedule(
      {
        name: "Pinned model check",
        trigger: { type: "at", at: 1_000, timeZone: "UTC" },
        action: { ...action(), model: "ds4/deepseek-v4-flash" },
      },
      500,
    );
    startSession.mockImplementationOnce(async (sessionId: string) => {
      const session = sessions.find((candidate) => candidate.id === sessionId);
      expect(session?.launch?.modelPolicy).toBe("required");
      throw new Error('Required model "ds4/deepseek-v4-flash" is not available');
    });
    const runner = new AgentScheduleRunner({
      storage: storage(),
      sessions: { startSession, sendPrompt },
      ensureSessionContextWindow: (session) => session,
      nowMs: () => 2_000,
    });

    await runner.runOnce();

    expect(sendPrompt).not.toHaveBeenCalled();
    expect(store.listRunSummaries(schedule.id)).toEqual([
      expect.objectContaining({
        status: "failed",
        error: 'Required model "ds4/deepseek-v4-flash" is not available',
      }),
    ]);
    expect(sessions[0]).toMatchObject({
      status: "error",
      model: "ds4/deepseek-v4-flash",
      launch: {
        modelPolicy: "required",
        status: "failed",
        promptDispatch: "not_sent",
        promptError: 'Required model "ds4/deepseek-v4-flash" is not available',
      },
    });
  });

  it("does not broadcast a discarded scheduled launch shell", async () => {
    const schedule = store.createSchedule(
      {
        name: "Constrained check",
        trigger: { type: "at", at: 1_000, timeZone: "UTC" },
        action: { ...action(), agentId: "agent-1" },
      },
      500,
    );
    const resolvedAgent = {
      id: "agent-1",
      version: 1,
      status: "active" as const,
      definition: {
        name: "Constrained check",
        launchConstraints: { allowedWorkspaceIds: ["other-workspace"] },
      },
    };
    const appEvents = {
      emitSessionCreated: vi.fn(),
      emitSessionSummary: vi.fn(),
    };
    const dispatchStorage = storage(resolvedAgent);
    const run = store.createDueRun(schedule.id, "at:1000", 1_000);
    const claimed = store.claimReadyRuns({
      now: 1_000,
      ownerId: "worker-a",
      leaseMs: 500,
      limit: 1,
      runIds: [run.id],
    })[0];

    await store.dispatchClaimedRun(
      claimed.id,
      createAgentScheduleDispatchHooks(
        {
          storage: dispatchStorage,
          sessions: { startSession, sendPrompt },
          ensureSessionContextWindow: (session) => session,
          appEvents,
        },
        "worker-a",
      ),
      { leaseOwner: "worker-a", now: 1_000 },
    ).catch(() => undefined);

    expect(appEvents.emitSessionCreated).not.toHaveBeenCalled();
    expect(appEvents.emitSessionSummary).not.toHaveBeenCalled();
    expect(sessions).toHaveLength(0);
    expect(store.getRun(run.id)).toMatchObject({ status: "failed" });
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

  it("materializes both repeated fall-back cron slots and skips a spring-forward gap", () => {
    const fallBack = store.createSchedule(
      {
        name: "Repeated local time",
        trigger: {
          type: "cron",
          expression: "30 1 * * *",
          timeZone: "America/New_York",
        },
        action: action(),
      },
      Date.parse("2026-10-31T00:00:00Z"),
    );
    const firstOccurrence = Date.parse("2026-11-01T05:30:00Z");
    const secondOccurrence = Date.parse("2026-11-01T06:30:00Z");

    expect(dueSlotKeysForSchedule(fallBack, firstOccurrence)).toEqual([`cron:${firstOccurrence}`]);
    expect(dueSlotKeysForSchedule(fallBack, secondOccurrence)).toEqual([
      `cron:${secondOccurrence}`,
    ]);

    const springForward = store.createSchedule(
      {
        name: "Missing local time",
        trigger: {
          type: "cron",
          expression: "30 2 * * *",
          timeZone: "America/New_York",
        },
        action: action(),
      },
      Date.parse("2026-03-07T00:00:00Z"),
    );

    expect(dueSlotKeysForSchedule(springForward, Date.parse("2026-03-08T06:30:00Z"))).toEqual([]);
    expect(dueSlotKeysForSchedule(springForward, Date.parse("2026-03-08T07:30:00Z"))).toEqual([]);
  });

  it("recovers after dispatch succeeds but run completion loses its lease", async () => {
    const schedule = store.createSchedule(
      {
        name: "Recover dispatched launch",
        trigger: { type: "at", at: 1_000, timeZone: "UTC" },
        action: action("Send exactly once"),
      },
      500,
    );
    const run = store.createDueRun(schedule.id, "at:1000", 1_000);
    const firstClaim = store.claimReadyRuns({
      now: 1_000,
      ownerId: "worker-a",
      leaseMs: 500,
      limit: 1,
      runIds: [run.id],
    })[0];
    let recoveredClaimId: string | undefined;
    sendPrompt.mockImplementationOnce(async () => {
      const recovered = store.claimReadyRuns({
        now: 2_000,
        ownerId: "worker-b",
        leaseMs: 10_000,
        limit: 1,
        runIds: [run.id],
      });
      expect(recovered).toEqual([
        expect.objectContaining({ id: run.id, status: "claimed", leaseOwner: "worker-b" }),
      ]);
      recoveredClaimId = recovered[0]?.id;
    });
    const dispatchStorage = storage();

    await expect(
      store.dispatchClaimedRun(
        firstClaim.id,
        createAgentScheduleDispatchHooks(
          {
            storage: dispatchStorage,
            sessions: { startSession, sendPrompt },
            ensureSessionContextWindow: (session) => session,
          },
          "worker-a",
        ),
        { leaseOwner: "worker-a", now: 1_000 },
      ),
    ).rejects.toThrow("lease was lost");

    expect(recoveredClaimId).toBe(run.id);
    expect(startSession).toHaveBeenCalledTimes(1);
    expect(sendPrompt).toHaveBeenCalledTimes(1);
    expect(sessions).toHaveLength(1);
    expect(sessions[0]?.launch?.promptDispatch).toBe("delivered");

    store.close();
    store = new AgentScheduleStore(dataDir);
    const recoveredRun = store.getRun(run.id);
    expect(recoveredRun).toMatchObject({ status: "claimed", leaseOwner: "worker-b" });

    await store.dispatchClaimedRun(
      recoveredRun?.id ?? "missing",
      createAgentScheduleDispatchHooks(
        {
          storage: dispatchStorage,
          sessions: { startSession, sendPrompt },
          ensureSessionContextWindow: (session) => session,
        },
        "worker-b",
      ),
      { leaseOwner: "worker-b", now: 2_000 },
    );

    expect(startSession).toHaveBeenCalledTimes(1);
    expect(sendPrompt).toHaveBeenCalledTimes(1);
    expect(store.getRun(run.id)).toMatchObject({
      status: "completed",
      result: { existing: true, promptDispatch: "delivered", sessionId: sessions[0]?.id },
    });
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
