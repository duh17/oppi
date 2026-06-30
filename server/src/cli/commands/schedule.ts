/* eslint-disable no-console, local/structured-log-format */
import { readFileSync } from "node:fs";

import * as c from "../../ansi.js";
import type { Storage } from "../../storage.js";
import {
  localApiRequest,
  type LocalApiHostResolvers,
  type LocalApiRequestOptions,
} from "../local-api-client.js";
import { writeJsonEnvelope } from "../output.js";
import { apiStatus, resolveWorkspaceIdForCli } from "../resources.js";

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
  storage: Storage,
  flags: Record<string, string>,
  prompt: string,
  hostResolvers: LocalApiHostResolvers,
): Promise<Record<string, unknown>> {
  const workspaceRef = flags.workspace?.trim();
  if (!workspaceRef) throw new Error("--workspace or --session is required");
  const workspaceId = await resolveWorkspaceIdForCli(storage, workspaceRef, hostResolvers);
  const approvalRefs = approvalRefsFromFlags(flags);
  return {
    type: "new_session",
    workspaceId,
    prompt,
    ...(flags.model ? { model: flags.model } : {}),
    ...(flags.worktree ? { worktreeId: flags.worktree } : {}),
    ...(flags.name ? { name: flags.name } : {}),
    ...(approvalRefs ? { approvalRefs } : {}),
  };
}

async function existingSessionAction(
  storage: Storage,
  sessionId: string,
  prompt: string,
  flags: Record<string, string>,
  hostResolvers: LocalApiHostResolvers,
): Promise<Record<string, unknown>> {
  const result = await localApiRequest<{ session?: { workspaceId?: string } }>(
    storage,
    `/sessions/${encodeURIComponent(sessionId)}`,
    undefined,
    hostResolvers,
  );
  const workspaceId = result.session?.workspaceId;
  if (!workspaceId)
    throw new Error("Session has no workspaceId; cannot create existing-session schedule");
  const approvalRefs = approvalRefsFromFlags(flags);
  return {
    type: "existing_session",
    workspaceId,
    sessionId,
    prompt,
    ...(approvalRefs ? { approvalRefs } : {}),
  };
}

function parseJsonFile(path: string): Record<string, unknown> {
  const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("definition must be a JSON object");
  }
  return parsed as Record<string, unknown>;
}

function querySuffix(params: URLSearchParams): string {
  const query = params.toString();
  return query ? `?${query}` : "";
}

function approvalRefsFromFlags(
  flags: Record<string, string>,
): Record<string, unknown>[] | undefined {
  const raw = flags["approval-ref"]?.trim();
  if (!raw) return undefined;
  const refs = raw
    .split(",")
    .map((ref) => ref.trim())
    .filter((ref) => ref.length > 0);
  if (refs.length === 0) return undefined;
  const now = Date.now();
  return refs.map((ref) => ({
    id: ref,
    ref,
    status: "accepted",
    acceptedAt: now,
    provenance: {
      extensionDisplayName: "Oppi CLI",
      recordedAt: now,
    },
  }));
}

function validateAgentFlag(agent: string | undefined): void {
  if (!agent) return;
  const normalized = agent.trim();
  if (!normalized || normalized === "default" || normalized === "workspace_default") return;
  throwSavedAgentError();
}

function throwSavedAgentError(): never {
  throw new Error(
    "Saved Agent definitions are not implemented; omit --agent to use workspace defaults",
  );
}

export async function cmdSchedule(
  storage: Storage,
  action: string | undefined,
  positional: string[],
  flags: Record<string, string>,
  hostResolvers: LocalApiHostResolvers = {},
): Promise<void> {
  const mode = action || "list";
  const jsonOutput = flags.json === "true";

  async function call<T>(path: string, options?: LocalApiRequestOptions): Promise<T> {
    return localApiRequest<T>(storage, path, options, hostResolvers);
  }

  function output(data: Record<string, unknown>, human: () => void): void {
    if (jsonOutput) writeJsonEnvelope({ ok: true, data });
    else human();
  }

  try {
    if (mode === "list") {
      if (flags.agent) throwSavedAgentError();
      const params = new URLSearchParams();
      if (flags.workspace) {
        const workspaceId = await resolveWorkspaceIdForCli(storage, flags.workspace, hostResolvers);
        params.set("workspaceId", workspaceId);
      }
      if (flags.session) params.set("sessionId", flags.session);
      const result = await call<Record<string, unknown>>(`/schedules${querySuffix(params)}`);
      output(result, () => {
        const schedules = Array.isArray(result.schedules) ? result.schedules : [];
        console.log(c.bold(`  Schedules (${schedules.length})`));
        for (const schedule of schedules as Array<{
          id?: string;
          name?: string;
          status?: string;
        }>) {
          console.log(
            `  ${c.cyan(schedule.id ?? "?")}  ${schedule.status ?? "?"}  ${schedule.name ?? "(unnamed)"}`,
          );
        }
        console.log("");
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
        console.log(c.green("  Schedule"));
        console.log(`  ID:     ${c.cyan(schedule?.id ?? id)}`);
        console.log(`  Name:   ${schedule?.name ?? "(unnamed)"}`);
        console.log(`  Status: ${schedule?.status ?? "?"}`);
        console.log("");
      });
      return;
    }

    if (mode === "create") {
      if (flags.agent) validateAgentFlag(flags.agent);
      if (flags["server-default-agent"] === "true") {
        throw new Error("Server default Agent schedules are not implemented yet");
      }
      const prompt = flags.prompt;
      if (!prompt?.trim()) throw new Error("--prompt is required");
      const name = flags.name || `Schedule ${new Date().toISOString()}`;
      const trigger = scheduleTriggerFromFlags(flags);
      const action = flags.session
        ? await existingSessionAction(storage, flags.session, prompt, flags, hostResolvers)
        : await newSessionAction(storage, flags, prompt, hostResolvers);
      const body = { name, trigger, action };
      const result = await call<Record<string, unknown>>("/schedules", { method: "POST", body });
      output(result, () => {
        const schedule = result.schedule as { id?: string } | undefined;
        console.log(c.green("  ✓ Schedule created"));
        console.log(`  Schedule: ${c.cyan(schedule?.id ?? "?")}`);
        console.log("");
        console.log(c.bold("  Next commands:"));
        console.log(`    ${c.dim(`oppi schedule run ${schedule?.id ?? "<id>"}`)}`);
        console.log(`    ${c.dim(`oppi schedule runs ${schedule?.id ?? "<id>"}`)}`);
        console.log("");
      });
      return;
    }

    if (mode === "update") {
      const id = positional[0];
      if (!id) throw new Error("schedule id is required");
      const definitionPath = flags.definition?.trim();
      if (!definitionPath) throw new Error("--definition is required");
      const definition = parseJsonFile(definitionPath);
      const result = await call<Record<string, unknown>>(`/schedules/${encodeURIComponent(id)}`, {
        method: "PATCH",
        body: definition,
      });
      output(result, () => {
        const schedule = result.schedule as
          | { id?: string; name?: string; status?: string }
          | undefined;
        console.log(c.green("  ✓ Schedule updated"));
        console.log(`  Schedule: ${c.cyan(schedule?.id ?? id)}`);
        console.log(`  Status:   ${schedule?.status ?? "?"}`);
        console.log("");
      });
      return;
    }

    if (["run", "runs", "pause", "resume", "archive"].includes(mode)) {
      const id = positional[0];
      if (!id) throw new Error("schedule id is required");
      if (mode === "runs") {
        const params = new URLSearchParams();
        if (flags.limit) params.set("limit", flags.limit);
        const result = await call<Record<string, unknown>>(
          `/schedules/${encodeURIComponent(id)}/runs${querySuffix(params)}`,
        );
        output(result, () => {
          const runs = Array.isArray(result.runs) ? result.runs : [];
          console.log(c.bold(`  Runs for ${id} (${runs.length})`));
          for (const run of runs as Array<{ id?: string; status?: string; sessionId?: string }>) {
            console.log(`  ${c.cyan(run.id ?? "?")}  ${run.status ?? "?"}  ${run.sessionId ?? ""}`);
          }
          console.log("");
        });
        return;
      }
      const requestId = flags["request-id"] || `${Date.now()}`;
      const result = await call<Record<string, unknown>>(
        `/schedules/${encodeURIComponent(id)}/${mode}`,
        { method: "POST", body: mode === "run" ? { requestId } : undefined },
      );
      output(result, () => {
        console.log(c.green(`  ✓ schedule ${mode}`));
        if ((result.run as { id?: string; sessionId?: string } | undefined)?.id) {
          const run = result.run as { id?: string; sessionId?: string };
          console.log(`  Run:     ${c.cyan(run.id ?? "?")}`);
          if (run.sessionId) console.log(`  Session: ${c.cyan(run.sessionId)}`);
        }
        console.log("");
      });
      return;
    }

    throw new Error("Usage: oppi schedule list|get|create|update|run|runs|pause|resume|archive");
  } catch (err: unknown) {
    const status = apiStatus(err);
    const message = err instanceof Error ? err.message : String(err);
    if (jsonOutput) {
      writeJsonEnvelope({ ok: false, error: { message, ...(status ? { status } : {}) } });
      process.exitCode = 1;
      return;
    }
    console.log(c.red(`  Error: ${message}`));
    process.exit(1);
  }
}
