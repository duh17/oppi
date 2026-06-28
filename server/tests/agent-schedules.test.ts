import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

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

    await store.dispatchClaimedRun(newRun.id, {
      launchNewSession: async ({ run }) => {
        launched.push(run.id);
        return { sessionId: "created-session" };
      },
      sendExistingSessionInput: async () => {
        throw new Error("unexpected existing-session hook");
      },
    });
    await store.dispatchClaimedRun(existingRun.id, {
      launchNewSession: async () => {
        throw new Error("unexpected launch hook");
      },
      sendExistingSessionInput: async ({ run, action }) => {
        inputs.push(`${action.sessionId}:${run.idempotencyKey}`);
        return { duplicate: false };
      },
    });

    expect(launched).toEqual([newRun.id]);
    expect(inputs).toEqual([`sess-1:${existingRun.idempotencyKey}`]);
    expect(store.getRun(newRun.id)?.status).toBe("completed");
    expect(store.getRun(existingRun.id)?.status).toBe("completed");
  });
});
