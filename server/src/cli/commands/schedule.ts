import { localApiRequest, type LocalApiConnection } from "../local-api-client.js";
import { createLocalApiCommandContext, handleModelResolvingCliError } from "../command-support.js";
import { readDefinitionInput } from "../definition-input.js";
import {
  codeValue,
  nonEmptyDetails,
  printDetails,
  printList,
  printNextCommands,
} from "../output.js";
import { resolveModelFlagForCli } from "../model-resolution.js";
import { resolveWorkspaceIdForCli } from "../resources.js";

function parseDurationMs(value: string): number {
  const match = value.trim().match(/^(\d+)(ms|s|m|h|d)$/);
  if (!match) throw new Error("Duration must look like 15m, 1h, or 1d");
  const amountText = match[1];
  const unit = match[2];
  if (!amountText || !unit) throw new Error("Duration must look like 15m, 1h, or 1d");
  const amount = Number.parseInt(amountText, 10);
  const multiplier =
    unit === "ms"
      ? 1
      : unit === "s"
        ? 1_000
        : unit === "m"
          ? 60_000
          : unit === "h"
            ? 3_600_000
            : 86_400_000;
  return amount * multiplier;
}

function scheduleTriggerFromFlags(flags: Record<string, string>): Record<string, unknown> {
  const timeZone = flags.tz || Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
  if (flags.at) {
    const at = Date.parse(flags.at);
    if (!Number.isFinite(at)) throw new Error("--at must be an ISO timestamp");
    return { type: "at", at, timeZone };
  }
  if (flags.every) {
    return { type: "every", intervalMs: parseDurationMs(flags.every), timeZone };
  }
  if (flags.cron) {
    return { type: "cron", expression: flags.cron, timeZone };
  }
  throw new Error("one of --at, --every, or --cron is required");
}

async function newSessionAction(
  storage: LocalApiConnection,
  flags: Record<string, string>,
  prompt: string,
): Promise<Record<string, unknown>> {
  const workspaceRef = flags.workspace?.trim();
  if (!workspaceRef) throw new Error("--workspace or --session is required");
  const workspaceId = await resolveWorkspaceIdForCli(storage, workspaceRef);
  const agentId = savedAgentReference(flags.agent);
  const resolvedModel = await resolveModelFlagForCli(storage, flags.model);
  return {
    type: "new_session",
    workspaceId,
    prompt,
    ...(agentId ? { agentId } : {}),
    ...(resolvedModel ? { model: resolvedModel.canonicalId } : {}),
    ...(resolvedModel?.thinkingLevel ? { thinkingLevel: resolvedModel.thinkingLevel } : {}),
    ...(flags.worktree ? { worktreeId: flags.worktree } : {}),
    ...(flags.name ? { name: flags.name } : {}),
  };
}

async function existingSessionAction(
  storage: LocalApiConnection,
  sessionId: string,
  prompt: string,
): Promise<Record<string, unknown>> {
  const result = await localApiRequest<{ session?: { workspaceId?: string } }>(
    storage,
    `/sessions/${encodeURIComponent(sessionId)}`,
  );
  const workspaceId = result.session?.workspaceId;
  if (!workspaceId)
    throw new Error("Session has no workspaceId; cannot create existing-session schedule");
  return {
    type: "existing_session",
    workspaceId,
    sessionId,
    prompt,
  };
}

function querySuffix(params: URLSearchParams): string {
  const query = params.toString();
  return query ? `?${query}` : "";
}

function savedAgentReference(agent: string | undefined): string | undefined {
  const normalized = agent?.trim();
  if (!normalized || normalized === "default" || normalized === "workspace_default") {
    return undefined;
  }
  return normalized;
}

export async function cmdSchedule(
  storage: LocalApiConnection,
  action: string | undefined,
  positional: string[],
  flags: Record<string, string>,
): Promise<void> {
  const mode = action || "list";
  const jsonOutput = flags.json === "true";

  const { call, output } = createLocalApiCommandContext(storage, jsonOutput);

  try {
    if (mode === "list") {
      const params = new URLSearchParams();
      if (flags.workspace) {
        const workspaceId = await resolveWorkspaceIdForCli(storage, flags.workspace);
        params.set("workspaceId", workspaceId);
      }
      if (flags.session) params.set("sessionId", flags.session);
      const agentId = savedAgentReference(flags.agent);
      if (agentId) params.set("agentId", agentId);
      const result = await call<Record<string, unknown>>(`/schedules${querySuffix(params)}`);
      output(result, () => {
        const schedules = Array.isArray(result.schedules)
          ? (result.schedules as Array<{ id?: string; name?: string; status?: string }>)
          : [];
        printList(
          `Schedules (${schedules.length})`,
          schedules.map((schedule) => ({
            id: schedule.id ?? "?",
            status: schedule.status ?? "?",
            title: schedule.name ?? "(unnamed)",
          })),
          { empty: "No schedules configured." },
        );
      });
      return;
    }

    if (mode === "get") {
      const id = positional[0];
      if (!id) throw new Error("schedule id is required");
      const result = await call<Record<string, unknown>>(`/schedules/${encodeURIComponent(id)}`);
      output(result, () => {
        const schedule = result.schedule as
          | { id?: string; name?: string; status?: string }
          | undefined;
        printDetails("Schedule", [
          ["ID", codeValue(schedule?.id ?? id)],
          ["Name", schedule?.name ?? "(unnamed)"],
          ["Status", schedule?.status ?? "?"],
        ]);
      });
      return;
    }

    if (mode === "create") {
      const prompt = flags.prompt;
      if (!prompt?.trim()) throw new Error("--prompt is required");
      const name = flags.name || `Schedule ${new Date().toISOString()}`;
      const trigger = scheduleTriggerFromFlags(flags);
      if (flags.session && savedAgentReference(flags.agent)) {
        throw new Error("--agent can only be used with new-session schedules");
      }
      const action = flags.session
        ? await existingSessionAction(storage, flags.session, prompt)
        : await newSessionAction(storage, flags, prompt);
      const body = { name, trigger, action };
      const result = await call<Record<string, unknown>>("/schedules", { method: "POST", body });
      output(result, () => {
        const schedule = result.schedule as { id?: string } | undefined;
        printDetails("✓ Schedule created", [["Schedule", codeValue(schedule?.id ?? "?")]]);
        printNextCommands([
          `oppi schedule run ${schedule?.id ?? "<id>"}`,
          `oppi schedule runs ${schedule?.id ?? "<id>"}`,
        ]);
      });
      return;
    }

    if (mode === "update") {
      const id = positional[0];
      if (!id) throw new Error("schedule id is required");
      const hasDefinition =
        flags.definition !== undefined || flags["definition-json"] !== undefined;
      if (flags.model !== undefined && !flags.model.trim()) {
        throw new Error("--model requires a non-empty value");
      }
      const hasModelUpdate = flags.model !== undefined || flags["clear-model"] === "true";
      if (hasDefinition && hasModelUpdate) {
        throw new Error("--model or --clear-model cannot be combined with a definition input");
      }
      if (!hasDefinition && !hasModelUpdate) {
        throw new Error(
          "one of --definition, --definition-json, --model, or --clear-model is required",
        );
      }
      if (flags.model !== undefined && flags["clear-model"] === "true") {
        throw new Error("--model and --clear-model cannot be combined");
      }
      const resolvedModel =
        flags["clear-model"] === "true"
          ? undefined
          : await resolveModelFlagForCli(storage, flags.model);
      const definition = hasDefinition
        ? readDefinitionInput(flags, { required: true, update: true })
        : {
            action: {
              model: flags["clear-model"] === "true" ? null : resolvedModel?.canonicalId,
              ...(resolvedModel?.thinkingLevel
                ? { thinkingLevel: resolvedModel.thinkingLevel }
                : {}),
            },
          };
      const result = await call<Record<string, unknown>>(`/schedules/${encodeURIComponent(id)}`, {
        method: "PATCH",
        body: definition,
      });
      output(result, () => {
        const schedule = result.schedule as
          | { id?: string; name?: string; status?: string }
          | undefined;
        printDetails("✓ Schedule updated", [
          ["Schedule", codeValue(schedule?.id ?? id)],
          ["Status", schedule?.status ?? "?"],
        ]);
      });
      return;
    }

    if (["run", "runs", "pause", "resume", "archive", "restore"].includes(mode)) {
      const id = positional[0];
      if (!id) throw new Error("schedule id is required");
      if (mode === "runs") {
        const params = new URLSearchParams();
        if (flags.limit) params.set("limit", flags.limit);
        const result = await call<Record<string, unknown>>(
          `/schedules/${encodeURIComponent(id)}/runs${querySuffix(params)}`,
        );
        output(result, () => {
          const runs = Array.isArray(result.runs)
            ? (result.runs as Array<{ id?: string; status?: string; sessionId?: string }>)
            : [];
          printList(
            `Runs for ${id} (${runs.length})`,
            runs.map((run) => ({
              id: run.id ?? "?",
              status: run.status ?? "?",
              title: run.sessionId ? `session ${run.sessionId}` : "(no session)",
            })),
            { empty: "No runs returned." },
          );
        });
        return;
      }
      const requestId = flags["request-id"] || `${Date.now()}`;
      const result = await call<Record<string, unknown>>(
        `/schedules/${encodeURIComponent(id)}/${mode}`,
        { method: "POST", body: mode === "run" ? { requestId } : undefined },
      );
      output(result, () => {
        const run = result.run as { id?: string; sessionId?: string } | undefined;
        printDetails(
          `✓ Schedule ${mode}`,
          nonEmptyDetails([
            ["Schedule", codeValue(id)],
            ["Run", run?.id ? codeValue(run.id) : ""],
            ["Session", run?.sessionId ? codeValue(run.sessionId) : ""],
          ]),
        );
      });
      return;
    }

    throw new Error(
      "Usage: oppi schedule list|get|create|update|run|runs|pause|resume|archive|restore",
    );
  } catch (err: unknown) {
    handleModelResolvingCliError(err, jsonOutput);
  }
}
