import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  AgentScheduleStore,
  mergeScheduleActionPatch,
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
    };

    return store.createSchedule({
      name: "Morning checks",
      trigger: { type: "at", at: 1_000, timeZone: "America/Los_Angeles" },
      action,
      ...overrides,
    });
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

  it("rejects invalid schedule time zones and cron expressions before persistence", () => {
    expect(() =>
      createSchedule({
        trigger: { type: "cron", expression: "not-a-cron", timeZone: "UTC" },
      }),
    ).toThrow("Schedule cron expression must have 5 fields");

    expect(() =>
      createSchedule({
        trigger: { type: "cron", expression: "0 9 * * *", timeZone: "Mars/Phobos" },
      }),
    ).toThrow("Schedule timeZone is invalid: Mars/Phobos");
  });

  it("persists thinking overrides in schedules and frozen run snapshots", () => {
    const schedule = createSchedule({
      action: {
        type: "new_session",
        workspaceId: "ws-1",
        prompt: "Run automatically",
        thinkingLevel: "high",
      },
    });
    const run = store.createManualRun(schedule.id, "thinking-snapshot");

    expect(store.getSchedule(schedule.id)?.action).toMatchObject({ thinkingLevel: "high" });
    expect(store.getRun(run.id)?.actionSnapshot).toMatchObject({ thinkingLevel: "high" });
  });

  it("rejects blank explicit models and invalid thinking levels", () => {
    expect(() =>
      createSchedule({
        action: {
          type: "new_session",
          workspaceId: "ws-1",
          prompt: "Run automatically",
          model: "   ",
        },
      }),
    ).toThrow("Schedule action model cannot be empty");

    expect(() =>
      createSchedule({
        action: {
          type: "new_session",
          workspaceId: "ws-1",
          prompt: "Run automatically",
          thinkingLevel: "extreme",
        } as AgentScheduleAction,
      }),
    ).toThrow("Schedule action thinkingLevel is invalid");
  });

  it("rejects removed approval fields from new schedule definitions", () => {
    expect(() =>
      createSchedule({
        action: {
          type: "new_session",
          workspaceId: "ws-1",
          prompt: "Run automatically",
          approvalRefs: ["obsolete"],
        } as AgentScheduleAction & { approvalRefs: string[] },
      }),
    ).toThrow("Schedule action has unexpected field: approvalRefs");
  });

  it("restores archived schedules as active and clears archive metadata", () => {
    const schedule = createSchedule();

    expect(store.archiveSchedule(schedule.id, 2_000)).toMatchObject({
      status: "archived",
      archivedAt: 2_000,
    });
    const restored = store.restoreSchedule(schedule.id, 3_000);
    expect(restored).toMatchObject({ status: "active", updatedAt: 3_000 });
    expect(restored?.archivedAt).toBeUndefined();
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

  it("reclaims a claimed run after process restart only when its lease expires", () => {
    const schedule = createSchedule();
    const run = store.createDueRun(schedule.id, "at:1000", 1_000);
    store.claimReadyRuns({
      now: 1_000,
      ownerId: "worker-a",
      leaseMs: 500,
      limit: 1,
      runIds: [run.id],
    });

    store.close();
    store = new AgentScheduleStore(dataDir);

    expect(
      store.claimReadyRuns({
        now: 1_499,
        ownerId: "worker-b",
        leaseMs: 10_000,
        limit: 1,
        runIds: [run.id],
      }),
    ).toEqual([]);
    expect(
      store.claimReadyRuns({
        now: 1_500,
        ownerId: "worker-b",
        leaseMs: 10_000,
        limit: 1,
        runIds: [run.id],
      }),
    ).toEqual([expect.objectContaining({ id: run.id, status: "claimed", leaseOwner: "worker-b" })]);
  });

  it.each(["paused", "archived"] as const)(
    "dispatches a frozen claimed run when its schedule becomes %s",
    async (nextStatus) => {
      const schedule = createSchedule();
      const run = store.claimReadyRuns({
        now: 1_000,
        ownerId: "worker",
        leaseMs: 10_000,
        limit: 1,
        runIds: [store.createDueRun(schedule.id, "at:1000", 1_000).id],
      })[0];
      if (nextStatus === "paused") store.pauseSchedule(schedule.id, 1_100);
      else store.archiveSchedule(schedule.id, 1_100);
      const launch = vi.fn(async () => ({ sessionId: "created-session" }));

      await store.dispatchClaimedRun(
        run.id,
        {
          launchNewSession: launch,
          sendExistingSessionInput: async () => {
            throw new Error("unexpected existing-session hook");
          },
        },
        { leaseOwner: "worker", now: 1_200 },
      );

      expect(launch).toHaveBeenCalledWith(
        expect.objectContaining({
          action: expect.objectContaining({ prompt: "Run the checks" }),
          schedule: expect.objectContaining({ status: nextStatus }),
        }),
      );
      expect(store.getRun(run.id)?.status).toBe("completed");
    },
  );

  it("stores frozen action snapshots on runs", () => {
    const schedule = createSchedule();
    const run = store.createManualRun(schedule.id, "snap-1");

    store.updateSchedule(schedule.id, {
      action: { type: "new_session", workspaceId: "ws-1", prompt: "Changed prompt" },
    });

    const reloaded = store.getRun(run.id);
    expect(reloaded?.actionSnapshot).toEqual(schedule.action);
  });

  it("list, get, and runs expose redacted summaries for history", () => {
    const schedule = createSchedule({
      action: {
        type: "existing_session",
        workspaceId: "ws-1",
        sessionId: "sess-1",
        prompt: "secret prompt body",
        streamingBehavior: "followUp",
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
      expect.objectContaining({ trigger: schedule.trigger }),
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

  it("summarizes saved-Agent new-session schedules without prompt bodies", () => {
    const schedule = createSchedule({
      action: {
        type: "new_session",
        workspaceId: "ws-1",
        agentId: "agent-1",
        prompt: "secret saved Agent prompt",
      },
    });
    const run = store.createManualRun(schedule.id, "history-agent");

    expect(store.getScheduleSummary(schedule.id)).toEqual(
      expect.objectContaining({
        action: {
          type: "new_session",
          workspaceId: "ws-1",
          agentId: "agent-1",
          promptChars: 25,
        },
      }),
    );
    expect(store.listRunSummaries(schedule.id)).toEqual([
      expect.objectContaining({
        id: run.id,
        action: {
          type: "new_session",
          workspaceId: "ws-1",
          agentId: "agent-1",
          promptChars: 25,
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

  it("dispatches due runs for active schedules", async () => {
    const schedule = createSchedule({
      action: { type: "new_session", workspaceId: "ws-1", prompt: "Run automatically" },
    });
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

  it("prevents stale lease owners from dispatching reclaimed runs", async () => {
    const schedule = createSchedule({
      action: {
        type: "new_session",
        workspaceId: "ws-1",
        prompt: "Run once",
      },
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
      },
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

  it("records a deterministic history-write serialization failure after dispatch succeeds", async () => {
    const schedule = createSchedule();
    const run = store.claimReadyRuns({
      now: 1_000,
      ownerId: "worker",
      leaseMs: 10_000,
      limit: 1,
      runIds: [store.createDueRun(schedule.id, "at:1000", 1_000).id],
    })[0];
    const launch = vi.fn(async () => ({ nonSerializable: 1n }));

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
    ).rejects.toThrow(/BigInt/);

    expect(launch).toHaveBeenCalledTimes(1);
    expect(store.getRun(run.id)).toMatchObject({
      status: "failed",
      completedAt: 1_000,
    });
    expect(store.getRun(run.id)?.error).toMatch(/BigInt/);
  });

  it("merges action patches without requiring callers to repeat preserved fields", () => {
    const current: AgentScheduleAction = {
      type: "new_session",
      workspaceId: "ws-1",
      prompt: "Keep this long prompt",
      agentId: "agent-1",
      model: "openai-codex/gpt-5.5",
      thinkingLevel: "medium",
      worktreeId: "main",
    };

    expect(
      mergeScheduleActionPatch(current, {
        model: "ds4/deepseek-v4-flash",
        thinkingLevel: "high",
      }),
    ).toEqual({
      ...current,
      model: "ds4/deepseek-v4-flash",
      thinkingLevel: "high",
    });
    expect(
      mergeScheduleActionPatch(current, {
        model: null,
        thinkingLevel: null,
        worktreeId: null,
      }),
    ).toEqual({
      type: "new_session",
      workspaceId: "ws-1",
      prompt: "Keep this long prompt",
      agentId: "agent-1",
    });
    expect(() =>
      mergeScheduleActionPatch(current, { type: "existing_session", model: "other" }),
    ).toThrow();
  });

  it("reclaims running runs after their lease expires", () => {
    const schedule = createSchedule({
      action: {
        type: "new_session",
        workspaceId: "ws-1",
        prompt: "Recover me",
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
