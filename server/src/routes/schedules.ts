import type { ServerResponse } from "node:http";

import { AgentLaunchService } from "../agent-launch-service.js";
import type {
  AgentScheduleRun,
  AgentScheduleStore,
  CreateAgentScheduleRequest,
} from "../agent-schedules.js";
import { safeErrorMessage } from "../log-utils.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const MANUAL_RUN_LEASE_MS = 10 * 60_000;
const MANUAL_RUN_OWNER = "schedule-api-run";

export function createScheduleRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  function getSchedules(): AgentScheduleStore {
    return ctx.storage.getAgentScheduleStore();
  }

  async function handleScheduleCollection(
    method: string,
    req: Parameters<RouteDispatcher>[0]["req"],
    res: ServerResponse,
  ): Promise<boolean> {
    if (method === "GET") {
      const schedules = getSchedules();
      helpers.json(res, { schedules: schedules.listScheduleSummaries() });
      return true;
    }

    if (method === "POST") {
      try {
        const schedules = getSchedules();
        const body = await helpers.parseBody<CreateAgentScheduleRequest>(req);
        validateScheduleTargets(body);
        const schedule = schedules.createSchedule(body);
        helpers.json(res, { schedule: schedules.getScheduleSummary(schedule.id) }, 201);
      } catch (error) {
        helpers.error(res, 400, safeErrorMessage(error));
      }
      return true;
    }

    return false;
  }

  async function handleScheduleMember(
    scheduleId: string,
    method: string,
    req: Parameters<RouteDispatcher>[0]["req"],
    res: ServerResponse,
  ): Promise<boolean> {
    if (method === "GET") {
      const schedules = getSchedules();
      const schedule = schedules.getScheduleSummary(scheduleId);
      if (!schedule) {
        helpers.error(res, 404, "Schedule not found");
        return true;
      }
      helpers.json(res, { schedule });
      return true;
    }

    if (method === "PATCH") {
      try {
        const schedules = getSchedules();
        const body = await helpers.parseBody<Partial<CreateAgentScheduleRequest>>(req);
        if (body.action || body.trigger || body.name) {
          validateScheduleTargets({
            name: body.name ?? "schedule",
            trigger: body.trigger ?? { type: "at", at: Date.now(), timeZone: "UTC" },
            action: body.action ?? schedules.getSchedule(scheduleId)?.action,
          });
        }
        const schedule = schedules.updateSchedule(scheduleId, body);
        if (!schedule) {
          helpers.error(res, 404, "Schedule not found");
          return true;
        }
        helpers.json(res, { schedule: schedules.getScheduleSummary(schedule.id) });
      } catch (error) {
        helpers.error(res, 400, safeErrorMessage(error));
      }
      return true;
    }

    return false;
  }

  function handleScheduleState(
    scheduleId: string,
    action: "pause" | "resume" | "archive",
    method: string,
    res: ServerResponse,
  ): boolean {
    if (method !== "POST") return false;
    const schedules = getSchedules();
    const schedule =
      action === "pause"
        ? schedules.pauseSchedule(scheduleId)
        : action === "resume"
          ? schedules.resumeSchedule(scheduleId)
          : schedules.archiveSchedule(scheduleId);
    if (!schedule) {
      helpers.error(res, 404, "Schedule not found");
      return true;
    }
    helpers.json(res, { schedule: schedules.getScheduleSummary(schedule.id) });
    return true;
  }

  async function handleManualRun(
    scheduleId: string,
    method: string,
    req: Parameters<RouteDispatcher>[0]["req"],
    res: ServerResponse,
  ): Promise<boolean> {
    if (method !== "POST") return false;
    try {
      const schedules = getSchedules();
      const body = await helpers.parseBody<{ requestId?: unknown }>(req);
      if (typeof body.requestId !== "string" || body.requestId.trim().length === 0) {
        helpers.error(res, 400, "requestId is required");
        return true;
      }
      const run = schedules.createManualRun(scheduleId, body.requestId);
      const dispatchable = run.status === "pending" || run.status === "claimed";
      const completedRun = dispatchable ? await claimAndDispatchRun(scheduleId, run) : run;
      helpers.json(
        res,
        { run: summarizeRun(scheduleId, completedRun) },
        run === completedRun ? 200 : 201,
      );
    } catch (error) {
      helpers.error(res, 400, safeErrorMessage(error));
    }
    return true;
  }

  async function claimAndDispatchRun(
    scheduleId: string,
    run: AgentScheduleRun,
  ): Promise<AgentScheduleRun> {
    const schedules = getSchedules();
    const now = Date.now();
    const claimed = schedules.claimReadyRuns({
      now,
      ownerId: MANUAL_RUN_OWNER,
      leaseMs: MANUAL_RUN_LEASE_MS,
      limit: 1,
      runIds: [run.id],
    })[0];
    if (!claimed) {
      return schedules.getRun(run.id) ?? run;
    }
    return schedules.dispatchClaimedRun(
      claimed.id,
      {
        launchNewSession: async ({ run: launchRun, action }) => {
          const workspace = ctx.storage.getWorkspace(action.workspaceId);
          if (!workspace) throw new Error("Workspace not found");
          const launchService = new AgentLaunchService({
            storage: ctx.storage,
            sessions: ctx.sessions,
            ensureSessionContextWindow: ctx.ensureSessionContextWindow,
          });
          const result = await launchService.launch({
            agent: {
              name: action.name?.trim() || `Schedule ${scheduleId}`,
              sessionDefaults: {
                ...(action.model ? { model: action.model } : {}),
              },
            },
            target: { workspace, ...(action.worktreeId ? { worktreeId: action.worktreeId } : {}) },
            prompt: action.prompt,
            idempotencyKey: launchRun.idempotencyKey,
            leaseOwner: MANUAL_RUN_OWNER,
            source: "schedule",
            schedule: {
              scheduleId,
              runId: launchRun.id,
              slotKey: launchRun.slotKey,
            },
            sessionName: action.name,
          });
          if (result.kind === "launch_in_progress") {
            throw new Error("launch_in_progress");
          }
          ctx.appEvents?.emitSessionCreated(result.createdSession);
          if (result.summarySession) ctx.appEvents?.emitSessionSummary(result.summarySession);
          return {
            sessionId: result.session.id,
            promptDispatch: result.promptDispatch,
            existing: result.kind === "existing",
          };
        },
        sendExistingSessionInput: async ({ run: inputRun, action }) => {
          const session = ctx.storage.getSession(action.sessionId);
          if (!session) throw new Error("Session not found");
          if (session.workspaceId !== action.workspaceId) {
            throw new Error("Session does not belong to schedule workspace");
          }
          await ctx.sessions.sendPrompt(action.sessionId, action.prompt, {
            requestId: inputRun.idempotencyKey,
            ...(action.streamingBehavior ? { streamingBehavior: action.streamingBehavior } : {}),
          });
          return { sessionId: action.sessionId, promptDispatch: "delivered" };
        },
      },
      now,
    );
  }

  return async ({ method, path, req, res }) => {
    if (path === "/schedules") {
      return handleScheduleCollection(method, req, res);
    }

    const member = path.match(/^\/schedules\/([^/]+)$/);
    if (member?.[1]) {
      return handleScheduleMember(decodeURIComponent(member[1]), method, req, res);
    }

    const runs = path.match(/^\/schedules\/([^/]+)\/runs$/);
    if (runs?.[1]) {
      if (method !== "GET") return false;
      const scheduleId = decodeURIComponent(runs[1]);
      const schedules = getSchedules();
      if (!schedules.getSchedule(scheduleId)) {
        helpers.error(res, 404, "Schedule not found");
        return true;
      }
      helpers.json(res, { runs: schedules.listRunSummaries(scheduleId) });
      return true;
    }

    const manualRun = path.match(/^\/schedules\/([^/]+)\/run$/);
    if (manualRun?.[1]) {
      return handleManualRun(decodeURIComponent(manualRun[1]), method, req, res);
    }

    const state = path.match(/^\/schedules\/([^/]+)\/(pause|resume|archive)$/);
    if (state?.[1] && state[2]) {
      return handleScheduleState(
        decodeURIComponent(state[1]),
        state[2] as "pause" | "resume" | "archive",
        method,
        res,
      );
    }

    return false;
  };

  function validateScheduleTargets(request: Partial<CreateAgentScheduleRequest>): void {
    const action = request.action;
    if (!action) return;
    const workspace = ctx.storage.getWorkspace(action.workspaceId);
    if (!workspace) throw new Error("Workspace not found");
    if (action.type === "existing_session") {
      const session = ctx.storage.getSession(action.sessionId);
      if (!session) throw new Error("Session not found");
      if (session.workspaceId !== action.workspaceId) {
        throw new Error("Session does not belong to schedule workspace");
      }
    }
  }

  function summarizeRun(scheduleId: string, run: AgentScheduleRun): unknown {
    const schedules = getSchedules();
    return (
      schedules.listRunSummaries(scheduleId).find((candidate) => candidate.id === run.id) ?? run
    );
  }
}
