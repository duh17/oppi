import type { ServerResponse } from "node:http";

import { createAgentScheduleDispatchHooks } from "../agent-schedule-dispatch.js";
import {
  mergeScheduleActionPatch,
  validateAgentScheduleUpdate,
  validateCreateAgentScheduleRequest,
} from "../agent-schedules.js";
import type {
  AgentScheduleRun,
  AgentScheduleStore,
  AgentScheduleSummary,
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
    url: URL,
    req: Parameters<RouteDispatcher>[0]["req"],
    res: ServerResponse,
  ): Promise<boolean> {
    if (method === "GET") {
      const schedules = getSchedules();
      helpers.json(res, {
        schedules: filterScheduleSummaries(schedules.listScheduleSummaries(), url),
      });
      return true;
    }

    if (method === "POST") {
      try {
        const schedules = getSchedules();
        const body = validateCreateAgentScheduleRequest(await helpers.parseBody<unknown>(req));
        const normalizedBody = normalizeScheduleRequestTargets(body);
        const now = Date.now();
        const schedule = schedules.createSchedule(normalizedBody, now);
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
      const resolved = resolveScheduleSummary(scheduleId, res);
      if (!resolved) return true;
      const schedule = getSchedules().getSchedule(resolved.id);
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
        const schedule = resolveScheduleSummary(scheduleId, res);
        if (!schedule) return true;
        const current = schedules.getSchedule(schedule.id);
        if (!current) {
          helpers.error(res, 404, "Schedule not found");
          return true;
        }
        const body = validateAgentScheduleUpdate(await helpers.parseBody<unknown>(req));
        const normalizedBody = {
          ...body,
          ...(body.action
            ? {
                action: normalizeScheduleActionTarget(
                  mergeScheduleActionPatch(current.action, body.action),
                ),
              }
            : {}),
        };
        const now = Date.now();
        const updated = schedules.updateSchedule(schedule.id, normalizedBody, now);
        if (!updated) {
          helpers.error(res, 404, "Schedule not found");
          return true;
        }
        helpers.json(res, { schedule: schedules.getScheduleSummary(updated.id) });
      } catch (error) {
        helpers.error(res, 400, safeErrorMessage(error));
      }
      return true;
    }

    return false;
  }

  function handleScheduleState(
    scheduleId: string,
    action: "pause" | "resume" | "archive" | "restore",
    method: string,
    res: ServerResponse,
  ): boolean {
    if (method !== "POST") return false;
    const schedules = getSchedules();
    const resolved = resolveScheduleSummary(scheduleId, res);
    if (!resolved) return true;
    const schedule =
      action === "pause"
        ? schedules.pauseSchedule(resolved.id)
        : action === "resume"
          ? schedules.resumeSchedule(resolved.id)
          : action === "archive"
            ? schedules.archiveSchedule(resolved.id)
            : schedules.restoreSchedule(resolved.id);
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
      const resolved = resolveScheduleSummary(scheduleId, res);
      if (!resolved) return true;
      const body = await helpers.parseBody<{ requestId?: unknown }>(req);
      if (typeof body.requestId !== "string" || body.requestId.trim().length === 0) {
        helpers.error(res, 400, "requestId is required");
        return true;
      }
      const run = schedules.createManualRun(resolved.id, body.requestId);
      const dispatchable = run.status === "pending" || run.status === "claimed";
      const completedRun = dispatchable ? await claimAndDispatchRun(run) : run;
      helpers.json(
        res,
        { run: summarizeRun(resolved.id, completedRun) },
        run === completedRun ? 200 : 201,
      );
    } catch (error) {
      helpers.error(res, 400, safeErrorMessage(error));
    }
    return true;
  }

  async function claimAndDispatchRun(run: AgentScheduleRun): Promise<AgentScheduleRun> {
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
      createAgentScheduleDispatchHooks(
        {
          storage: ctx.storage,
          sessions: ctx.sessions,
          ensureSessionContextWindow: ctx.ensureSessionContextWindow,
          appEvents: ctx.appEvents,
        },
        MANUAL_RUN_OWNER,
      ),
      { leaseOwner: MANUAL_RUN_OWNER, now },
    );
  }

  return async ({ method, path, url, req, res }) => {
    if (path === "/schedules") {
      return handleScheduleCollection(method, url, req, res);
    }

    const member = path.match(/^\/schedules\/([^/]+)$/);
    if (member?.[1]) {
      return handleScheduleMember(decodeURIComponent(member[1]), method, req, res);
    }

    const runs = path.match(/^\/schedules\/([^/]+)\/runs$/);
    if (runs?.[1]) {
      if (method !== "GET") return false;
      const schedule = resolveScheduleSummary(decodeURIComponent(runs[1]), res);
      if (!schedule) return true;
      const schedules = getSchedules();
      const limit = parsePositiveIntegerQueryParam(url.searchParams.get("limit"), res);
      if (limit === null) return true;
      helpers.json(res, {
        runs: schedules.listRunSummaries(schedule.id, limit === undefined ? undefined : { limit }),
      });
      return true;
    }

    const manualRun = path.match(/^\/schedules\/([^/]+)\/run$/);
    if (manualRun?.[1]) {
      return handleManualRun(decodeURIComponent(manualRun[1]), method, req, res);
    }

    const state = path.match(/^\/schedules\/([^/]+)\/(pause|resume|archive|restore)$/);
    if (state?.[1] && state[2]) {
      return handleScheduleState(
        decodeURIComponent(state[1]),
        state[2] as "pause" | "resume" | "archive" | "restore",
        method,
        res,
      );
    }

    return false;
  };

  function filterScheduleSummaries(
    schedules: AgentScheduleSummary[],
    url: URL,
  ): AgentScheduleSummary[] {
    const workspaceId = url.searchParams.get("workspaceId")?.trim();
    const sessionId = url.searchParams.get("sessionId")?.trim();
    const status = url.searchParams.get("status")?.trim();
    const agentReference = url.searchParams.get("agentId")?.trim();
    const resolvedAgentId = agentReference
      ? ctx.storage.getAgentDefinitionStore().resolveAgent(agentReference)?.id
      : undefined;
    if (agentReference && !resolvedAgentId) return [];
    return schedules.filter((schedule) => {
      if (workspaceId && schedule.action.workspaceId !== workspaceId) return false;
      if (sessionId && schedule.action.sessionId !== sessionId) return false;
      if (resolvedAgentId && schedule.action.agentId !== resolvedAgentId) return false;
      if (status && schedule.status !== status) return false;
      return true;
    });
  }

  function resolveScheduleSummary(
    reference: string,
    res: ServerResponse,
  ): AgentScheduleSummary | null {
    const schedules = getSchedules();
    const direct = schedules.getScheduleSummary(reference);
    if (direct) return direct;

    const matches = schedules
      .listScheduleSummaries()
      .filter((schedule) => schedule.name === reference);
    if (matches.length === 1) return matches[0];
    if (matches.length > 1) {
      helpers.error(res, 409, "Schedule name is ambiguous");
      return null;
    }
    helpers.error(res, 404, "Schedule not found");
    return null;
  }

  function parsePositiveIntegerQueryParam(
    raw: string | null,
    res: ServerResponse,
  ): number | undefined | null {
    if (raw === null) return undefined;
    const value = raw.trim();
    if (!value) return undefined;
    if (!/^[1-9]\d*$/.test(value)) {
      helpers.error(res, 400, "limit must be a positive integer");
      return null;
    }
    const parsed = Number(value);
    if (!Number.isSafeInteger(parsed)) {
      helpers.error(res, 400, "limit must be a positive integer");
      return null;
    }
    return parsed;
  }

  function normalizeScheduleRequestTargets(
    request: CreateAgentScheduleRequest,
  ): CreateAgentScheduleRequest {
    return { ...request, action: normalizeScheduleActionTarget(request.action) };
  }

  function normalizeScheduleActionTarget(
    action: CreateAgentScheduleRequest["action"],
  ): CreateAgentScheduleRequest["action"] {
    const workspace = ctx.storage.getWorkspace(action.workspaceId);
    if (!workspace) throw new Error("Workspace not found");
    if (action.type === "new_session") {
      if (!action.agentId) return action;
      const agent = ctx.storage.getAgentDefinitionStore().resolveAgent(action.agentId);
      if (!agent || agent.status === "archived") throw new Error("Agent not found");
      return { ...action, agentId: agent.id };
    }
    const session = ctx.storage.getSession(action.sessionId);
    if (!session) throw new Error("Session not found");
    if (session.workspaceId !== action.workspaceId) {
      throw new Error("Session does not belong to schedule workspace");
    }
    return action;
  }

  function summarizeRun(scheduleId: string, run: AgentScheduleRun): unknown {
    const schedules = getSchedules();
    return (
      schedules.listRunSummaries(scheduleId).find((candidate) => candidate.id === run.id) ?? run
    );
  }
}
