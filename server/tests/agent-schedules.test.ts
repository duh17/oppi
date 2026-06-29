import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  AgentScheduleStore,
  type AgentScheduleAction,
  type CreateAgentScheduleRequest,
} from "../src/agent-schedules.js";

describe("agent schedule durable core", () => {
  let dataDir: string;
  let store: AgentScheduleStore;

  beforeEach(() => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-schedules-"));
    store = new AgentScheduleStore(dataDir);
  });

  afterEach(() => {
    store.close();
    rmSync(dataDir, { recursive: true, force: true });
  });

  function createSchedule(overrides: Partial<CreateAgentScheduleRequest> = {}) {
    const action: AgentScheduleAction = {
      type: "new_session",
      workspaceId: "ws-1",
      prompt: "Run the checks",
      model: "openai-codex/gpt-5.5",
      approvalRefs: [{ ref: "approval://local/one", label: "Local approval" }],
    };

    return store.createSchedule({
      name: "Morning checks",
      trigger: { type: "at", at: 1_000, timeZone: "America/Los_Angeles" },
      action,
      ...overrides,
    });
  }

  function recordAcceptedApprovalEvent(input: {
    approvalRefId: string;
    scheduleId?: string;
    runId?: string;
    workspaceId?: string;
    createdAt?: number;
  }): void {
    const createdAt = input.createdAt ?? 1;
    Reflect.get(store, "db")
      .prepare(
        `INSERT INTO server_agent_extension_audit_events (
           id, created_at, workspace_id, schedule_id, run_id, event_type, approval_ref_id, envelope_json
         ) VALUES (?, ?, ?, ?, ?, 'approval_ref.accepted', ?, ?)`,
      )
      .run(
        `audit:${createdAt}:${input.approvalRefId}:${input.scheduleId ?? ""}:${input.runId ?? ""}`,
        createdAt,
        input.workspaceId ?? "ws-1",
        input.scheduleId ?? null,
        input.runId ?? null,
        input.approvalRefId,
        JSON.stringify({ eventType: "approval_ref.accepted", approvalRefId: input.approvalRefId }),
      );
  }

  it("creates schedules with at, every, and cron trigger shapes and concrete time zones", () => {
    const at = createSchedule();
    const every = createSchedule({
      name: "Every fifteen",
      trigger: { type: "every", intervalMs: 15 * 60 * 1000, timeZone: "UTC" },
    });
    const cron = createSchedule({
      name: "Weekday cron",
      trigger: { type: "cron", expression: "0 9 * * 1-5", timeZone: "America/New_York" },
    });

    expect(at.trigger).toEqual({ type: "at", at: 1_000, timeZone: "America/Los_Angeles" });
    expect(every.trigger).toEqual({ type: "every", intervalMs: 900_000, timeZone: "UTC" });
    expect(cron.trigger).toEqual({
      type: "cron",
      expression: "0 9 * * 1-5",
      timeZone: "America/New_York",
    });
    expect(new Set(store.listSchedules().map((schedule) => schedule.id))).toEqual(
      new Set([at.id, every.id, cron.id]),
    );
    expect(store.getSchedule(cron.id)?.name).toBe("Weekday cron");
  });

  it("manual run creates one run with a request id idempotency key", () => {
    const schedule = createSchedule();

    const first = store.createManualRun(schedule.id, "button-press-1");
    const second = store.createManualRun(schedule.id, "button-press-1");

    expect(second.id).toBe(first.id);
    expect(first.idempotencyKey).toBe(`schedule:${schedule.id}:manual:button-press-1`);
    expect(first.slotKey).toBe("manual:button-press-1");
    expect(store.listRuns(schedule.id)).toHaveLength(1);
  });

  it("due slot inserts are unique by schedule/slot and idempotency key", () => {
    const schedule = createSchedule();

    const first = store.createDueRun(schedule.id, "at:1000");
    const second = store.createDueRun(schedule.id, "at:1000");

    expect(second.id).toBe(first.id);
    expect(first.idempotencyKey).toBe(`schedule:${schedule.id}:slot:at:1000`);
    expect(store.listRuns(schedule.id)).toHaveLength(1);
  });

  it("claims expired leases and leaves unexpired leases alone", () => {
    const schedule = createSchedule();
    const run = store.createDueRun(schedule.id, "at:1000");

    expect(
      store.claimReadyRuns({ now: 1_000, ownerId: "worker-a", leaseMs: 10_000, limit: 1 }),
    ).toEqual([
      expect.objectContaining({ id: run.id, leaseOwner: "worker-a", leaseExpiresAt: 11_000 }),
    ]);
    expect(
      store.claimReadyRuns({ now: 2_000, ownerId: "worker-b", leaseMs: 10_000, limit: 1 }),
    ).toEqual([]);
    expect(
      store.claimReadyRuns({ now: 12_000, ownerId: "worker-b", leaseMs: 10_000, limit: 1 }),
    ).toEqual([
      expect.objectContaining({ id: run.id, leaseOwner: "worker-b", leaseExpiresAt: 22_000 }),
    ]);
  });

  it("stores frozen action snapshots and opaque approval refs on runs", () => {
    const schedule = createSchedule();
    const run = store.createManualRun(schedule.id, "snap-1");

    store.updateSchedule(schedule.id, {
      action: { type: "new_session", workspaceId: "ws-1", prompt: "Changed prompt" },
    });

    const reloaded = store.getRun(run.id);
    expect(reloaded?.actionSnapshot).toEqual(schedule.action);
    expect(reloaded?.approvalRefs).toEqual([
      { ref: "approval://local/one", label: "Local approval" },
    ]);
  });

  it("list, get, and runs expose redacted summaries for history", () => {
    const schedule = createSchedule({
      action: {
        type: "existing_session",
        workspaceId: "ws-1",
        sessionId: "sess-1",
        prompt: "secret prompt body",
        streamingBehavior: "followUp",
        approvalRefs: [{ token: "opaque" }],
      },
    });
    const run = store.createManualRun(schedule.id, "history-1");

    expect(store.listScheduleSummaries()).toEqual([
      expect.objectContaining({
        id: schedule.id,
        name: "Morning checks",
        action: {
          type: "existing_session",
          workspaceId: "ws-1",
          sessionId: "sess-1",
          promptChars: 18,
        },
      }),
    ]);
    expect(store.getScheduleSummary(schedule.id)).toEqual(
      expect.objectContaining({ trigger: schedule.trigger, approvalRefCount: 1 }),
    );
    expect(store.listRunSummaries(schedule.id)).toEqual([
      expect.objectContaining({
        id: run.id,
        action: {
          type: "existing_session",
          workspaceId: "ws-1",
          sessionId: "sess-1",
          promptChars: 18,
        },
      }),
    ]);
  });

  it("limits run summaries in the store query", () => {
    const schedule = createSchedule();
    const first = store.createManualRun(schedule.id, "history-1", 1);
    const second = store.createManualRun(schedule.id, "history-2", 2);
    store.createManualRun(schedule.id, "history-3", 3);

    expect(store.listRunSummaries(schedule.id, { limit: 2 }).map((run) => run.id)).toEqual([
      first.id,
      second.id,
    ]);
  });

  it("dispatches claimed runs through new-session and existing-session integration hooks", async () => {
    const newSession = createSchedule();
    const existing = createSchedule({
      action: {
        type: "existing_session",
        workspaceId: "ws-1",
        sessionId: "sess-1",
        prompt: "Continue",
        approvalRefs: ["opaque"],
      },
    });
    const newRun = store.claimReadyRuns({
      now: 1_000,
      ownerId: "worker",
      leaseMs: 10_000,
      limit: 1,
      runIds: [store.createManualRun(newSession.id, "launch").id],
    })[0];
    const existingRun = store.claimReadyRuns({
      now: 1_000,
      ownerId: "worker",
      leaseMs: 10_000,
      limit: 1,
      runIds: [store.createManualRun(existing.id, "input").id],
    })[0];
    const launched: string[] = [];
    const inputs: string[] = [];

    await store.dispatchClaimedRun(
      newRun.id,
      {
        launchNewSession: async ({ run }) => {
          launched.push(run.id);
          return { sessionId: "created-session" };
        },
        sendExistingSessionInput: async () => {
          throw new Error("unexpected existing-session hook");
        },
      },
      { leaseOwner: "worker", now: 1_000 },
    );
    await store.dispatchClaimedRun(
      existingRun.id,
      {
        launchNewSession: async () => {
          throw new Error("unexpected launch hook");
        },
        sendExistingSessionInput: async ({ run, action }) => {
          inputs.push(`${action.sessionId}:${run.idempotencyKey}`);
          return { duplicate: false };
        },
      },
      { leaseOwner: "worker", now: 1_000 },
    );

    expect(launched).toEqual([newRun.id]);
    expect(inputs).toEqual([`sess-1:${existingRun.idempotencyKey}`]);
    expect(store.getRun(newRun.id)?.status).toBe("completed");
    expect(store.getRun(existingRun.id)?.status).toBe("completed");
  });

  it("fails closed for due runs without an accepted extension approval ref", async () => {
    const schedule = createSchedule({
      action: { type: "new_session", workspaceId: "ws-1", prompt: "Run without approval" },
    });
    const run = store.claimReadyRuns({
      now: 1_000,
      ownerId: "worker",
      leaseMs: 10_000,
      limit: 1,
      runIds: [store.createDueRun(schedule.id, "at:1000").id],
    })[0];
    const launch = vi.fn(async () => ({ sessionId: "should-not-run" }));

    await expect(
      store.dispatchClaimedRun(
        run.id,
        {
          launchNewSession: launch,
          sendExistingSessionInput: async () => {
            throw new Error("unexpected existing-session hook");
          },
        },
        { leaseOwner: "worker", now: 1_000 },
      ),
    ).rejects.toThrow("approval_required_noninteractive");

    expect(launch).not.toHaveBeenCalled();
    expect(store.getRun(run.id)).toMatchObject({
      status: "failed",
      error: "approval_required_noninteractive:missing_accepted_approval_ref",
    });
  });

  it("rejects scheduled approval refs without matching accepted audit provenance", async () => {
    const schedule = createSchedule({
      action: {
        type: "new_session",
        workspaceId: "ws-1",
        prompt: "Run with forged approval",
        approvalRefs: ["approval://forged"],
      },
    });
    const run = store.claimReadyRuns({
      now: 1_000,
      ownerId: "worker",
      leaseMs: 10_000,
      limit: 1,
      runIds: [store.createDueRun(schedule.id, "at:1000").id],
    })[0];
    const launch = vi.fn(async () => ({ sessionId: "should-not-run" }));

    await expect(
      store.dispatchClaimedRun(
        run.id,
        {
          launchNewSession: launch,
          sendExistingSessionInput: async () => {
            throw new Error("unexpected existing-session hook");
          },
        },
        { leaseOwner: "worker", now: 1_000 },
      ),
    ).rejects.toThrow("approval_required_noninteractive:missing_accepted_approval_provenance");

    expect(launch).not.toHaveBeenCalled();
    expect(store.getRun(run.id)).toMatchObject({
      status: "failed",
      error: "approval_required_noninteractive:missing_accepted_approval_provenance",
    });
  });

  it("dispatches scheduled runs with matching accepted audit provenance", async () => {
    const schedule = createSchedule({
      action: {
        type: "new_session",
        workspaceId: "ws-1",
        prompt: "Run with accepted approval",
        approvalRefs: ["approval://accepted"],
      },
    });
    recordAcceptedApprovalEvent({ approvalRefId: "approval://accepted", scheduleId: schedule.id });
    const run = store.claimReadyRuns({
      now: 1_000,
      ownerId: "worker",
      leaseMs: 10_000,
      limit: 1,
      runIds: [store.createDueRun(schedule.id, "at:1000").id],
    })[0];
    const launch = vi.fn(async () => ({ sessionId: "created-session" }));

    await store.dispatchClaimedRun(
      run.id,
      {
        launchNewSession: launch,
        sendExistingSessionInput: async () => {
          throw new Error("unexpected existing-session hook");
        },
      },
      { leaseOwner: "worker", now: 1_000 },
    );

    expect(launch).toHaveBeenCalledTimes(1);
    expect(store.getRun(run.id)).toMatchObject({ status: "completed" });
  });

  it("rejects scheduled approval provenance from another schedule", async () => {
    const other = createSchedule({ name: "Other schedule" });
    const schedule = createSchedule({
      name: "Target schedule",
      action: {
        type: "new_session",
        workspaceId: "ws-1",
        prompt: "Run with mismatched approval",
        approvalRefs: ["approval://shared"],
      },
    });
    recordAcceptedApprovalEvent({ approvalRefId: "approval://shared", scheduleId: other.id });
    const run = store.claimReadyRuns({
      now: 1_000,
      ownerId: "worker",
      leaseMs: 10_000,
      limit: 1,
      runIds: [store.createDueRun(schedule.id, "at:1000").id],
    })[0];
    const launch = vi.fn(async () => ({ sessionId: "should-not-run" }));

    await expect(
      store.dispatchClaimedRun(
        run.id,
        {
          launchNewSession: launch,
          sendExistingSessionInput: async () => {
            throw new Error("unexpected existing-session hook");
          },
        },
        { leaseOwner: "worker", now: 1_000 },
      ),
    ).rejects.toThrow("approval_required_noninteractive:missing_accepted_approval_provenance");

    expect(launch).not.toHaveBeenCalled();
  });

  it("prevents stale lease owners from dispatching reclaimed runs", async () => {
    const schedule = createSchedule({
      action: {
        type: "new_session",
        workspaceId: "ws-1",
        prompt: "Run once",
        approvalRefs: ["approval://schedule/run"],
      },
    });
    recordAcceptedApprovalEvent({
      approvalRefId: "approval://schedule/run",
      scheduleId: schedule.id,
    });
    const runId = store.createDueRun(schedule.id, "at:1000").id;
    const firstClaim = store.claimReadyRuns({
      now: 1_000,
      ownerId: "worker-a",
      leaseMs: 500,
      limit: 1,
      runIds: [runId],
    })[0];
    const secondClaim = store.claimReadyRuns({
      now: 2_000,
      ownerId: "worker-b",
      leaseMs: 10_000,
      limit: 1,
      runIds: [runId],
    })[0];
    const launch = vi.fn(async () => ({ sessionId: "created-session" }));

    await expect(
      store.dispatchClaimedRun(
        firstClaim.id,
        {
          launchNewSession: launch,
          sendExistingSessionInput: async () => {
            throw new Error("unexpected existing-session hook");
          },
        },
        { leaseOwner: "worker-a", now: 2_000 },
      ),
    ).rejects.toThrow("lease is not held");

    await store.dispatchClaimedRun(
      secondClaim.id,
      {
        launchNewSession: launch,
        sendExistingSessionInput: async () => {
          throw new Error("unexpected existing-session hook");
        },
      },
      { leaseOwner: "worker-b", now: 2_000 },
    );

    expect(launch).toHaveBeenCalledTimes(1);
    expect(store.getRun(runId)?.status).toBe("completed");
  });

  it("does not let a stale worker complete a run after another worker reclaims it", async () => {
    const schedule = createSchedule({
      action: {
        type: "new_session",
        workspaceId: "ws-1",
        prompt: "Run once",
        approvalRefs: ["approval://schedule/run"],
      },
    });
    recordAcceptedApprovalEvent({
      approvalRefId: "approval://schedule/run",
      scheduleId: schedule.id,
    });
    const runId = store.createDueRun(schedule.id, "at:1000").id;
    const firstClaim = store.claimReadyRuns({
      now: 1_000,
      ownerId: "worker-a",
      leaseMs: 500,
      limit: 1,
      runIds: [runId],
    })[0];
    const launch = vi.fn(async () => {
      expect(
        store.claimReadyRuns({
          now: 2_000,
          ownerId: "worker-b",
          leaseMs: 10_000,
          limit: 1,
          runIds: [runId],
        }),
      ).toEqual([
        expect.objectContaining({ id: runId, status: "claimed", leaseOwner: "worker-b" }),
      ]);
      return { sessionId: "stale-result" };
    });

    await expect(
      store.dispatchClaimedRun(
        firstClaim.id,
        {
          launchNewSession: launch,
          sendExistingSessionInput: async () => {
            throw new Error("unexpected existing-session hook");
          },
        },
        { leaseOwner: "worker-a", now: 1_000 },
      ),
    ).rejects.toThrow("lease was lost");

    expect(store.getRun(runId)).toMatchObject({ status: "claimed", leaseOwner: "worker-b" });
  });

  it("reclaims running runs after their lease expires", () => {
    const schedule = createSchedule({
      action: {
        type: "new_session",
        workspaceId: "ws-1",
        prompt: "Recover me",
        approvalRefs: ["approval://schedule/run"],
      },
    });
    const run = store.claimReadyRuns({
      now: 1_000,
      ownerId: "worker-a",
      leaseMs: 500,
      limit: 1,
      runIds: [store.createDueRun(schedule.id, "at:1000").id],
    })[0];
    Reflect.get(store, "db")
      .prepare("UPDATE agent_schedule_runs SET status = 'running' WHERE id = ?")
      .run(run.id);

    expect(
      store.claimReadyRuns({
        now: 2_000,
        ownerId: "worker-b",
        leaseMs: 10_000,
        limit: 1,
        runIds: [run.id],
      }),
    ).toEqual([expect.objectContaining({ id: run.id, status: "claimed", leaseOwner: "worker-b" })]);
  });
});
