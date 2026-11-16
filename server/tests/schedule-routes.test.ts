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
      definition: {
        name: string;
        icon?: { kind: "symbol"; name: string };
        sessionDefaults?: {
          model?: string;
          thinkingLevel?: "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
        };
      };
    }
  >;
  let responses: Array<{ data: unknown; status: number }>;
  let errors: Array<{ status: number; message: string }>;
  let startSession: ReturnType<typeof vi.fn>;
  let sendPrompt: ReturnType<typeof vi.fn>;
  let ctx: RouteContext;
  let helpers: RouteHelpers;
  let config: { features?: { schedules?: boolean } };

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
          definition: {
            name: "Reviewer",
            icon: { kind: "symbol", name: "checkmark.shield" },
            sessionDefaults: { model: "agent-model", thinkingLevel: "low" },
          },
        },
      ],
    ]);
    responses = [];
    errors = [];
    startSession = vi.fn(async (sessionId: string) => makeSession({ id: sessionId }));
    sendPrompt = vi.fn(async () => undefined);

    config = {};
    const storage = {
      getConfig: () => config,
      getAgentScheduleStore: () => store,
      getAgentDefinitionStore: () => ({
        getAgent: (agentId: string) => agents.get(agentId),
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
      // Every stored session: no schedule route may read them all, or its cost grows with
      // every session ever made.
      listSessions: vi.fn(() => {
        throw new Error("A schedule route read every stored session");
      }),
      listChildSessions: vi.fn((parentId: string) =>
        sessions.filter((session) => session.launch?.parentSessionId === parentId),
      ),
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

  it("creates once per idempotency key: a replay returns the schedule, another body is a conflict", async () => {
    const dispatch = createScheduleRoutes(ctx, helpers);
    const create = (body: Record<string, unknown>) =>
      dispatch({
        method: "POST",
        path: "/schedules",
        url: new URL("https://localhost/schedules"),
        req: requestBody(body),
        res: {} as ServerResponse,
      });
    const definition = {
      name: "Nightly",
      trigger: { type: "every", intervalMs: 3_600_000, timeZone: "UTC" },
      action: { type: "new_session", workspaceId: workspace.id, prompt: "go" },
    };

    await create({ ...definition, idempotencyKey: "call-1" });
    await create({ ...definition, idempotencyKey: "call-1" });
    await create({ ...definition, name: "Other", idempotencyKey: "call-1" });
    await create({ ...definition, name: "Other", idempotencyKey: "call-2" });

    expect(errors).toEqual([]);
    const [first, replay, conflict, second] = responses;
    expect(first?.status).toBe(201);
    expect(replay?.status).toBe(200);
    expect(replay?.data).toEqual(first?.data);
    expect(conflict).toMatchObject({
      status: 409,
      data: { code: "SCHEDULE_IDEMPOTENCY_CONFLICT" },
    });
    expect(second?.status).toBe(201);
    expect(
      store
        .listScheduleSummaries()
        .map((schedule) => schedule.name)
        .sort(),
    ).toEqual(["Nightly", "Other"]);
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
    expect(sessions[0]?.launch).toMatchObject({
      idempotencyKey: `schedule:${schedule.id}:manual:button-1`,
      modelPolicy: "required",
    });
  });

  it("refuses a run by hand while the server's Schedules switch is off", async () => {
    const schedule = store.createSchedule({
      name: "Morning check",
      trigger: { type: "at", at: 1_000, timeZone: "UTC" },
      action: { type: "new_session", workspaceId: workspace.id, prompt: "Run the checks" },
    });
    config = { features: { schedules: false } };
    const path = `/schedules/${schedule.id}/run`;

    await createScheduleRoutes(
      ctx,
      helpers,
    )({
      method: "POST",
      path,
      url: new URL(`https://localhost${path}`),
      req: requestBody({ requestId: "button-1" }),
      res: {} as ServerResponse,
    });

    expect(errors).toEqual([
      {
        status: 409,
        message: expect.stringContaining("Schedules feature is turned off on this server"),
      },
    ]);
    expect(store.listRuns(schedule.id)).toEqual([]);
    expect(startSession).not.toHaveBeenCalled();
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

  it("patches nested schedule actions without replacing preserved fields", async () => {
    const schedule = store.createSchedule({
      name: "Model update",
      trigger: { type: "at", at: 1_000, timeZone: "UTC" },
      action: {
        type: "new_session",
        workspaceId: workspace.id,
        agentId: "agent-1",
        model: "openai-codex/gpt-5.5",
        worktreeId: "main",
        prompt: "Keep this long prompt",
      },
    });
    const dispatch = createScheduleRoutes(ctx, helpers);
    const path = `/schedules/${schedule.id}`;

    await dispatch({
      method: "PATCH",
      path,
      url: new URL(`https://localhost${path}`),
      req: requestBody({ action: { model: "ds4/deepseek-v4-flash" } }),
      res: {} as ServerResponse,
    });
    await dispatch({
      method: "PATCH",
      path,
      url: new URL(`https://localhost${path}`),
      req: requestBody({ action: { model: null, worktreeId: null } }),
      res: {} as ServerResponse,
    });

    expect(errors).toEqual([]);
    expect(store.getSchedule(schedule.id)?.action).toEqual({
      type: "new_session",
      workspaceId: workspace.id,
      agentId: "agent-1",
      prompt: "Keep this long prompt",
    });
    expect(responses).toHaveLength(2);
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
        thinkingLevel: "max",
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
      thinkingLevel: "max",
      launch: {
        source: "schedule",
        agentId: "agent-1",
        agentVersion: 3,
        agentIcon: { kind: "symbol", name: "checkmark.shield" },
        modelPolicy: "required",
        thinkingLevel: "max",
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

  it("restores an archived schedule as active", async () => {
    const schedule = store.createSchedule({
      name: "Morning check",
      trigger: { type: "at", at: 1_000, timeZone: "UTC" },
      action: { type: "new_session", workspaceId: workspace.id, prompt: "Run the checks" },
    });
    store.archiveSchedule(schedule.id, 2_000);
    const dispatch = createScheduleRoutes(ctx, helpers);
    const path = `/schedules/${schedule.id}/restore`;

    await dispatch({
      method: "POST",
      path,
      url: new URL(`https://localhost${path}`),
      req: requestBody({}),
      res: {} as ServerResponse,
    });

    expect(errors).toEqual([]);
    expect(responses).toEqual([
      expect.objectContaining({
        data: { schedule: expect.objectContaining({ id: schedule.id, status: "active" }) },
      }),
    ]);
    expect(store.getSchedule(schedule.id)?.archivedAt).toBeUndefined();
  });

  it("returns newest run history first when descending order is requested", async () => {
    const schedule = store.createSchedule({
      name: "Morning check",
      trigger: { type: "at", at: 1_000, timeZone: "UTC" },
      action: { type: "new_session", workspaceId: workspace.id, prompt: "Run the checks" },
    });
    store.createManualRun(schedule.id, "history-oldest", 1);
    const middle = store.createManualRun(schedule.id, "history-middle", 2);
    const newest = store.createManualRun(schedule.id, "history-newest", 3);
    const dispatch = createScheduleRoutes(ctx, helpers);
    const path = `/schedules/${schedule.id}/runs`;

    await dispatch({
      method: "GET",
      path,
      url: new URL(`https://localhost${path}?limit=2&order=desc`),
      req: requestBody({}),
      res: {} as ServerResponse,
    });

    expect(errors).toEqual([]);
    const runs = (responses[0]?.data as { runs: Array<{ id: string }> }).runs;
    expect(runs.map((run) => run.id)).toEqual([newest.id, middle.id]);
  });

  it("answers the calendar, not a schedule named calendar, and refuses a bad range", async () => {
    const schedule = store.createSchedule(
      {
        name: "calendar",
        trigger: { type: "every", intervalMs: 3_600_000, timeZone: "UTC" },
        action: {
          type: "new_session",
          workspaceId: workspace.id,
          prompt: "go",
          agentId: "agent-1",
        },
      },
      0,
    );
    const dispatch = createScheduleRoutes(ctx, helpers);
    const get = (query: string) =>
      dispatch({
        method: "GET",
        path: "/schedules/calendar",
        url: new URL(`https://localhost/schedules/calendar?${query}`),
        req: requestBody({}),
        res: {} as ServerResponse,
      });
    const now = 1_794_400_000_123;
    const clock = vi.spyOn(Date, "now").mockReturnValue(now);

    await get(`from=${now}&to=${now + 3 * 3_600_000}`);
    clock.mockRestore();
    await get("from=10&to=5");

    expect(errors).toEqual([{ status: 400, message: "to must be after from" }]);
    const calendar = responses[0]?.data as {
      schedules: Array<{ id: string; model?: string }>;
      entries: Array<{ scheduleId: string; at: number }>;
    };
    expect(calendar.schedules).toEqual([
      expect.objectContaining({ id: schedule.id, model: "agent-model" }),
    ]);
    // Hourly from creation at 0: each whole hour after now, inside the three hours.
    const hours: number[] = [];
    for (
      let at = Math.floor(now / 3_600_000 + 1) * 3_600_000;
      at < now + 3 * 3_600_000;
      at += 3_600_000
    ) {
      hours.push(at);
    }
    expect(calendar.entries).toEqual(
      hours.map((at) => ({ scheduleId: schedule.id, slotKey: `every:${at}`, at })),
    );
  });

  it("joins a run's session and its children by parent, never reading every session", async () => {
    const schedule = store.createSchedule(
      {
        name: "Night shift",
        trigger: { type: "every", intervalMs: 3_600_000, timeZone: "UTC" },
        action: { type: "new_session", workspaceId: workspace.id, prompt: "go" },
      },
      0,
    );
    const ranAt = 7_200_000;
    store.createDueRun(schedule.id, `every:${ranAt}`, ranAt);
    const [claimed] = store.claimReadyRuns({ now: ranAt, ownerId: "t", leaseMs: 60_000, limit: 1 });
    if (!claimed) throw new Error("no run to claim");
    await store.dispatchClaimedRun(
      claimed.id,
      {
        launchNewSession: async () => ({ sessionId: "sess-night", promptDispatch: "delivered" }),
        sendExistingSessionInput: async () => ({
          sessionId: "sess-night",
          promptDispatch: "delivered",
        }),
      },
      { leaseOwner: "t", now: ranAt },
    );
    sessions.push(
      makeSession({ id: "sess-night", cost: 2 }),
      makeSession({ id: "kid", createdAt: ranAt + 1, launch: { parentSessionId: "sess-night" } }),
      makeSession({ id: "grandkid", createdAt: ranAt + 2, launch: { parentSessionId: "kid" } }),
      makeSession({ id: "stranger", launch: { parentSessionId: "elsewhere" } }),
    );
    const dispatch = createScheduleRoutes(ctx, helpers);

    await dispatch({
      method: "GET",
      path: "/schedules/calendar",
      url: new URL(`https://localhost/schedules/calendar?from=0&to=${ranAt + 1}`),
      req: requestBody({}),
      res: {} as ServerResponse,
    });

    expect(errors).toEqual([]);
    const calendar = responses[0]?.data as {
      entries: Array<{ run?: { session?: { id: string; descendants?: Array<{ id: string }> } } }>;
    };
    const session = calendar.entries.find((entry) => entry.run)?.run?.session;
    expect(session?.id).toBe("sess-night");
    expect(session?.descendants?.map((descendant) => descendant.id)).toEqual(["kid", "grandkid"]);
  });

  it("rejects malformed run history queries", async () => {
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

    for (const query of ["limit=2x", "limit=1.5", "order=sideways"] as const) {
      await dispatch({
        method: "GET",
        path,
        url: new URL(`https://localhost${path}?${query}`),
        req: requestBody({}),
        res: {} as ServerResponse,
      });
    }

    expect(responses).toEqual([]);
    expect(errors).toEqual([
      { status: 400, message: "limit must be a positive integer" },
      { status: 400, message: "limit must be a positive integer" },
      { status: 400, message: "order must be asc or desc" },
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
    expect(errors).toEqual([{ status: 400, message: "transport down" }]);
    expect(store.listRunSummaries(schedule.id)).toEqual([
      expect.objectContaining({
        status: "failed",
        error: "transport down",
      }),
    ]);
  });

  it("versions a schedule and refuses a stale prompt write", async () => {
    const schedule = store.createSchedule({
      name: "Prompt check",
      trigger: { type: "at", at: 1_000, timeZone: "UTC" },
      action: { type: "new_session", workspaceId: workspace.id, prompt: "Run the checks" },
    });
    const dispatch = createScheduleRoutes(ctx, helpers);
    const path = `/schedules/${schedule.id}`;
    const patch = (query: string, body: Record<string, unknown>) =>
      dispatch({
        method: "PATCH",
        path,
        url: new URL(`https://localhost${path}${query}`),
        req: requestBody(body),
        res: {} as ServerResponse,
      });

    // A read reports the version the editor's tag starts from.
    await dispatch({
      method: "GET",
      path,
      url: new URL(`https://localhost${path}`),
      req: requestBody({}),
      res: {} as ServerResponse,
    });
    const version = (responses[0]?.data as { schedule: { version: number } }).schedule.version;
    expect(version).toBe(0);

    await patch(`?expectedVersion=${version}`, { action: { prompt: "New prompt" } });
    await patch(`?expectedVersion=${version}`, { action: { prompt: "Stale prompt" } });
    await patch("?expectedVersion=0&unexpected=1", { action: { prompt: "Other" } });

    expect(errors).toEqual([
      { status: 400, message: "Unknown Schedule update query parameter: unexpected" },
    ]);
    expect(responses[1]).toMatchObject({
      status: 200,
      data: { schedule: { version: version + 1, action: { promptChars: 10 } } },
    });
    expect(responses[2]).toMatchObject({
      status: 409,
      data: {
        code: "SCHEDULE_VERSION_CONFLICT",
        expectedVersion: version,
        currentVersion: version + 1,
      },
    });
    expect(store.getSchedule(schedule.id)?.action).toMatchObject({ prompt: "New prompt" });
  });

  /// Pausing is not a definition change, so an editor holding the version it
  /// read can still save after someone pauses the schedule.
  it("a pause does not make an open editor's save stale", async () => {
    const schedule = store.createSchedule({
      name: "Pause check",
      trigger: { type: "at", at: 1_000, timeZone: "UTC" },
      action: { type: "new_session", workspaceId: workspace.id, prompt: "Run the checks" },
    });
    const dispatch = createScheduleRoutes(ctx, helpers);
    const path = `/schedules/${schedule.id}`;
    const version = store.getSchedule(schedule.id)?.version ?? -1;

    await dispatch({
      method: "POST",
      path: `${path}/pause`,
      url: new URL(`https://localhost${path}/pause`),
      req: requestBody({}),
      res: {} as ServerResponse,
    });
    await dispatch({
      method: "PATCH",
      path,
      url: new URL(`https://localhost${path}?expectedVersion=${version}`),
      req: requestBody({ action: { prompt: "Saved while paused" } }),
      res: {} as ServerResponse,
    });

    expect(errors).toEqual([]);
    expect(responses[0]).toMatchObject({ status: 200, data: { schedule: { status: "paused" } } });
    expect(responses[1]).toMatchObject({ status: 200 });
    expect(store.getSchedule(schedule.id)).toMatchObject({
      status: "paused",
      action: { prompt: "Saved while paused" },
    });
  });

  it("rejects unexpected schedule fields and empty updates", async () => {
    const schedule = store.createSchedule({
      name: "Morning check",
      trigger: { type: "at", at: 1_000, timeZone: "UTC" },
      action: { type: "new_session", workspaceId: workspace.id, prompt: "Run the checks" },
    });
    const dispatch = createScheduleRoutes(ctx, helpers);
    const path = `/schedules/${schedule.id}`;

    await dispatch({
      method: "PATCH",
      path,
      url: new URL(`https://localhost${path}`),
      req: requestBody({ name: "Updated", unexpected: true }),
      res: {} as ServerResponse,
    });
    await dispatch({
      method: "PATCH",
      path,
      url: new URL(`https://localhost${path}`),
      req: requestBody({ trigger: { type: "at", at: 2_000, timeZone: "UTC", unexpected: true } }),
      res: {} as ServerResponse,
    });
    await dispatch({
      method: "PATCH",
      path,
      url: new URL(`https://localhost${path}`),
      req: requestBody({}),
      res: {} as ServerResponse,
    });

    expect(responses).toEqual([]);
    expect(errors).toEqual([
      { status: 400, message: "Schedule update has unexpected field: unexpected" },
      { status: 400, message: "Schedule trigger has unexpected field: unexpected" },
      { status: 400, message: "Schedule update must include at least one field" },
    ]);
  });
});
