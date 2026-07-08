import type { IncomingMessage, ServerResponse } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { AgentScheduleStore } from "../src/agent-schedules.js";
import { createScheduleRoutes } from "../src/routes/schedules.js";
import type { RouteContext, RouteHelpers } from "../src/routes/types.js";
import type { Session, Workspace } from "../src/types.js";

function requestBody(body: Record<string, unknown>): IncomingMessage {
  const stream = new PassThrough();
  stream.end(JSON.stringify(body));
  return stream as unknown as IncomingMessage;
}

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

describe("schedule routes", () => {
  let dataDir: string;
  let store: AgentScheduleStore;
  let sessions: Session[];
  let agents: Map<
    string,
    {
      id: string;
      name: string;
      status: "active" | "archived";
      version: number;
      definition: { name: string; sessionDefaults?: { model?: string } };
    }
  >;
  let responses: Array<{ data: unknown; status: number }>;
  let errors: Array<{ status: number; message: string }>;
  let startSession: ReturnType<typeof vi.fn>;
  let sendPrompt: ReturnType<typeof vi.fn>;
  let ctx: RouteContext;
  let helpers: RouteHelpers;

  const workspace: Workspace = { id: "ws-1", name: "Workspace" } as Workspace;

  beforeEach(() => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-schedule-routes-"));
    store = new AgentScheduleStore(dataDir);
    sessions = [];
    agents = new Map([
      [
        "agent-1",
        {
          id: "agent-1",
          name: "Reviewer",
          status: "active",
          version: 3,
          definition: { name: "Reviewer", sessionDefaults: { model: "agent-model" } },
        },
      ],
    ]);
    responses = [];
    errors = [];
    startSession = vi.fn(async (sessionId: string) => makeSession({ id: sessionId }));
    sendPrompt = vi.fn(async () => undefined);

    const storage = {
      getAgentScheduleStore: () => store,
      getAgentDefinitionStore: () => ({
        resolveAgent: vi.fn(
          (agentId: string) =>
            agents.get(agentId) ??
            Array.from(agents.values()).find((agent) => agent.name === agentId),
        ),
      }),
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
    };

    ctx = {
      storage,
      sessions: { startSession, sendPrompt },
      ensureSessionContextWindow: (session: Session) => session,
      appEvents: {
        emitSessionCreated: vi.fn(),
        emitSessionSummary: vi.fn(),
      },
    } as unknown as RouteContext;
    helpers = {
      parseBody: async <T>(req: IncomingMessage): Promise<T> => {
        const chunks: Buffer[] = [];
        for await (const chunk of req) chunks.push(chunk as Buffer);
        const raw = Buffer.concat(chunks).toString("utf-8");
        return raw ? (JSON.parse(raw) as T) : ({} as T);
      },
      json: (_res: ServerResponse, data: unknown, status?: number) =>
        responses.push({ data, status: status ?? 200 }),
      compressedJson: (_req, _res, data, status) => responses.push({ data, status: status ?? 200 }),
      error: (_res, status, message) => errors.push({ status, message }),
    };
  });

  afterEach(() => {
    store.close();
    rmSync(dataDir, { recursive: true, force: true });
  });

  it("runs a new-session schedule through AgentLaunchService idempotently", async () => {
    const schedule = store.createSchedule({
      name: "Morning check",
      trigger: { type: "at", at: 1_000, timeZone: "UTC" },
      action: {
        type: "new_session",
        workspaceId: workspace.id,
        prompt: "Run the checks",
        model: "openai-codex/gpt-5.5",
      },
    });
    const dispatch = createScheduleRoutes(ctx, helpers);
    const path = `/schedules/${schedule.id}/run`;

    await dispatch({
      method: "POST",
      path,
      url: new URL(`https://localhost${path}`),
      req: requestBody({ requestId: "button-1" }),
      res: {} as ServerResponse,
    });
    await dispatch({
      method: "POST",
      path,
      url: new URL(`https://localhost${path}`),
      req: requestBody({ requestId: "button-1" }),
      res: {} as ServerResponse,
    });

    expect(errors).toEqual([]);
    expect(startSession).toHaveBeenCalledTimes(1);
    expect(sendPrompt).toHaveBeenCalledTimes(1);
    const firstRun = (responses[0]?.data as { run?: { sessionId?: string } }).run;
    expect(firstRun?.sessionId).toBeTruthy();
    expect(responses[0]).toMatchObject({
      status: 201,
      data: {
        run: {
          scheduleId: schedule.id,
          status: "completed",
          promptDispatch: "delivered",
        },
      },
    });
    expect(responses[1]).toMatchObject({
      status: 200,
      data: { run: { sessionId: firstRun?.sessionId, promptDispatch: "delivered" } },
    });
    expect(sessions).toHaveLength(1);
    expect(sessions[0]?.id).toBe(firstRun?.sessionId);
    expect(sessions[0]?.launch?.idempotencyKey).toBe(`schedule:${schedule.id}:manual:button-1`);
  });

  it("canonicalizes saved-Agent schedule targets by Agent name", async () => {
    const dispatch = createScheduleRoutes(ctx, helpers);
    const path = "/schedules";

    await dispatch({
      method: "POST",
      path,
      url: new URL(`https://localhost${path}`),
      req: requestBody({
        name: "Reviewer by name",
        trigger: { type: "at", at: 1_000, timeZone: "UTC" },
        action: {
          type: "new_session",
          workspaceId: workspace.id,
          agentId: "Reviewer",
          prompt: "Review the branch",
        },
      }),
      res: {} as ServerResponse,
    });

    expect(errors).toEqual([]);
    const scheduleId = (responses[0]?.data as { schedule?: { id?: string } }).schedule?.id;
    expect(scheduleId).toBeTruthy();
    expect(store.getSchedule(scheduleId ?? "")?.action).toMatchObject({ agentId: "agent-1" });
    expect(responses[0]).toMatchObject({
      data: { schedule: { action: { agentId: "agent-1" } } },
    });
  });

  it("runs a saved-Agent schedule with the stored Agent definition", async () => {
    const schedule = store.createSchedule({
      name: "Reviewer check",
      trigger: { type: "at", at: 1_000, timeZone: "UTC" },
      action: {
        type: "new_session",
        workspaceId: workspace.id,
        agentId: "agent-1",
        prompt: "Review the branch",
      },
    });
    const dispatch = createScheduleRoutes(ctx, helpers);
    const path = `/schedules/${schedule.id}/run`;

    await dispatch({
      method: "POST",
      path,
      url: new URL(`https://localhost${path}`),
      req: requestBody({ requestId: "button-agent" }),
      res: {} as ServerResponse,
    });

    expect(errors).toEqual([]);
    expect(startSession).toHaveBeenCalledTimes(1);
    expect(sendPrompt).toHaveBeenCalledWith(expect.any(String), "Review the branch", {});
    expect(sessions[0]).toMatchObject({
      model: "agent-model",
      launch: {
        source: "schedule",
        agentId: "agent-1",
        agentVersion: 3,
      },
    });
  });

  it("rejects schedules for unknown saved Agents", async () => {
    const dispatch = createScheduleRoutes(ctx, helpers);
    const path = "/schedules";

    await dispatch({
      method: "POST",
      path,
      url: new URL(`https://localhost${path}`),
      req: requestBody({
        name: "Missing Agent",
        trigger: { type: "at", at: 1_000, timeZone: "UTC" },
        action: {
          type: "new_session",
          workspaceId: workspace.id,
          agentId: "missing-agent",
          prompt: "Run the check",
        },
      }),
      res: {} as ServerResponse,
    });

    expect(responses).toEqual([]);
    expect(errors).toEqual([{ status: 400, message: "Agent not found" }]);
  });

  it("filters schedule summaries by saved Agent", async () => {
    const matching = store.createSchedule({
      name: "Reviewer check",
      trigger: { type: "at", at: 1_000, timeZone: "UTC" },
      action: {
        type: "new_session",
        workspaceId: workspace.id,
        agentId: "agent-1",
        prompt: "Review the branch",
      },
    });
    store.createSchedule({
      name: "Plain check",
      trigger: { type: "at", at: 2_000, timeZone: "UTC" },
      action: {
        type: "new_session",
        workspaceId: workspace.id,
        prompt: "Run the branch",
      },
    });
    const dispatch = createScheduleRoutes(ctx, helpers);
    const path = "/schedules";

    await dispatch({
      method: "GET",
      path,
      url: new URL(`https://localhost${path}?agentId=agent-1`),
      req: requestBody({}),
      res: {} as ServerResponse,
    });

    expect(errors).toEqual([]);
    expect(responses).toEqual([
      expect.objectContaining({
        data: {
          schedules: [
            expect.objectContaining({
              id: matching.id,
              action: expect.objectContaining({ agentId: "agent-1" }),
            }),
          ],
        },
      }),
    ]);
  });

  it("creates schedules whose due runs dispatch automatically", async () => {
    const dispatch = createScheduleRoutes(ctx, helpers);
    const path = "/schedules";

    await dispatch({
      method: "POST",
      path,
      url: new URL(`https://localhost${path}`),
      req: requestBody({
        name: "Daily review",
        trigger: { type: "cron", expression: "0 7 * * *", timeZone: "America/Los_Angeles" },
        action: {
          type: "new_session",
          workspaceId: workspace.id,
          prompt: "Run the daily review",
        },
      }),
      res: {} as ServerResponse,
    });

    expect(errors).toEqual([]);
    const scheduleId = (responses[0]?.data as { schedule?: { id?: string } }).schedule?.id;
    expect(scheduleId).toBeTruthy();
    const run = store.createDueRun(scheduleId ?? "", "cron:1000", 1_000);
    const claimed = store.claimReadyRuns({
      now: 1_000,
      ownerId: "runner",
      leaseMs: 10_000,
      limit: 1,
      runIds: [run.id],
    })[0];

    await store.dispatchClaimedRun(
      claimed?.id ?? "missing",
      {
        launchNewSession: vi.fn(async () => ({
          sessionId: "sess-scheduled",
          promptDispatch: "delivered",
        })),
        sendExistingSessionInput: vi.fn(),
      },
      { leaseOwner: "runner", now: 1_100 },
    );

    expect(store.listRunSummaries(scheduleId ?? "")).toEqual([
      expect.objectContaining({
        status: "completed",
        sessionId: "sess-scheduled",
      }),
    ]);
  });

  it("rejects malformed run history limits", async () => {
    const schedule = store.createSchedule({
      name: "Morning check",
      trigger: { type: "at", at: 1_000, timeZone: "UTC" },
      action: {
        type: "new_session",
        workspaceId: workspace.id,
        prompt: "Run the checks",
      },
    });
    const dispatch = createScheduleRoutes(ctx, helpers);
    const path = `/schedules/${schedule.id}/runs`;

    for (const limit of ["2x", "1.5"] as const) {
      await dispatch({
        method: "GET",
        path,
        url: new URL(`https://localhost${path}?limit=${limit}`),
        req: requestBody({}),
        res: {} as ServerResponse,
      });
    }

    expect(responses).toEqual([]);
    expect(errors).toEqual([
      { status: 400, message: "limit must be a positive integer" },
      { status: 400, message: "limit must be a positive integer" },
    ]);
  });

  it("fails a schedule run when new-session prompt dispatch is not delivered", async () => {
    sendPrompt.mockRejectedValueOnce(new Error("transport down"));
    const schedule = store.createSchedule({
      name: "Morning check",
      trigger: { type: "at", at: 1_000, timeZone: "UTC" },
      action: {
        type: "new_session",
        workspaceId: workspace.id,
        prompt: "Run the checks",
      },
    });
    const dispatch = createScheduleRoutes(ctx, helpers);
    const path = `/schedules/${schedule.id}/run`;

    await dispatch({
      method: "POST",
      path,
      url: new URL(`https://localhost${path}`),
      req: requestBody({ requestId: "button-fail" }),
      res: {} as ServerResponse,
    });

    expect(responses).toEqual([]);
    expect(errors).toEqual([{ status: 400, message: "prompt_not_sent" }]);
    expect(store.listRunSummaries(schedule.id)).toEqual([
      expect.objectContaining({
        status: "failed",
        error: "prompt_not_sent",
      }),
    ]);
  });
});
