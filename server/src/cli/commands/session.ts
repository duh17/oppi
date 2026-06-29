/* eslint-disable no-console, local/structured-log-format */
import * as c from "../../ansi.js";
import type { Storage } from "../../storage.js";
import type { Session } from "../../types.js";
import {
  localApiRequest,
  type LocalApiHostResolvers,
  type LocalApiRequestOptions,
} from "../local-api-client.js";
import { writeJsonEnvelope } from "../output.js";
import { apiStatus, resolveWorkspaceIdForCli } from "../resources.js";

type SessionTraceEvent = {
  type?: string;
  text?: string;
  message?: unknown;
  [key: string]: unknown;
};

export async function cmdSession(
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
      const params = new URLSearchParams();
      if (flags.workspace) {
        const workspaceId = await resolveWorkspaceIdForCli(storage, flags.workspace, hostResolvers);
        params.set("workspaceId", workspaceId);
      }
      if (flags.worktree) params.set("worktreeId", flags.worktree);
      if (flags.status) params.set("status", flags.status);
      if (flags.limit) params.set("limit", flags.limit);
      if (flags.agent) params.set("agentId", flags.agent);

      const result = await call<Record<string, unknown>>(`/sessions${querySuffix(params)}`);
      output(result, () => {
        const sessions = Array.isArray(result.sessions) ? result.sessions : [];
        console.log(c.bold(`  Sessions (${sessions.length})`));
        for (const session of sessions as Array<Partial<Session>>) {
          console.log(
            `  ${c.cyan(session.id ?? "?")}  ${session.status ?? "?"}  ${session.name ?? "(unnamed)"}`,
          );
        }
        console.log("");
      });
      return;
    }

    if (mode === "get") {
      const id = requirePositional(positional, "session id is required");
      const result = await call<Record<string, unknown>>(`/sessions/${encodeURIComponent(id)}`);
      output(result, () => {
        const session = result.session as Partial<Session> | undefined;
        console.log(c.green("  Session"));
        console.log(`  ID:        ${c.cyan(session?.id ?? id)}`);
        console.log(`  Status:    ${session?.status ?? "unknown"}`);
        if (session?.workspaceId) console.log(`  Workspace: ${c.cyan(session.workspaceId)}`);
        if (session?.worktreeId) console.log(`  Worktree:  ${session.worktreeId}`);
        console.log("");
      });
      return;
    }

    if (mode === "create") {
      await createSession(storage, flags, jsonOutput, hostResolvers);
      return;
    }

    if (mode === "send") {
      const id = requirePositional(positional, "session id is required");
      const text = flags.text;
      if (!text?.trim()) throw new Error("--text is required");
      const result = await call<Record<string, unknown>>(
        `/sessions/${encodeURIComponent(id)}/command`,
        { method: "POST", body: { type: "prompt", message: text } },
      );
      output(result, () => {
        console.log(c.green("  ✓ Message sent"));
        console.log(`  Session: ${c.cyan(id)}`);
        console.log("");
      });
      return;
    }

    if (mode === "read" || mode === "trace") {
      const id = requirePositional(positional, "session id is required");
      const params = new URLSearchParams();
      if (mode === "read" && flags.tail) params.set("tail", flags.tail);
      if (mode === "trace" && flags.include) params.set("include", flags.include);
      const result = await call<Record<string, unknown>>(
        `/sessions/${encodeURIComponent(id)}/${mode}${querySuffix(params)}`,
      );
      output(result, () => {
        const trace = Array.isArray(result.trace) ? (result.trace as SessionTraceEvent[]) : [];
        console.log(
          c.bold(`  ${mode === "read" ? "Messages" : "Trace"} for ${id} (${trace.length})`),
        );
        for (const event of trace) {
          console.log(`  ${c.cyan(event.type ?? "event")}  ${eventText(event)}`.trimEnd());
        }
        console.log("");
      });
      return;
    }

    if (mode === "events") {
      const id = requirePositional(positional, "session id is required");
      const params = new URLSearchParams();
      if (flags.since) params.set("since", flags.since);
      const result = await call<Record<string, unknown>>(
        `/sessions/${encodeURIComponent(id)}/events${querySuffix(params)}`,
      );
      output(result, () => {
        const events = Array.isArray(result.events) ? result.events : [];
        console.log(c.bold(`  Events for ${id} (${events.length})`));
        for (const event of events as Array<{ seq?: number; type?: string }>) {
          console.log(`  ${String(event.seq ?? "?").padStart(4)}  ${event.type ?? "event"}`);
        }
        console.log("");
      });
      return;
    }

    if (mode === "stop") {
      const id = requirePositional(positional, "session id is required");
      const result = await call<Record<string, unknown>>(
        `/sessions/${encodeURIComponent(id)}/stop`,
        {
          method: "POST",
        },
      );
      output(result, () => {
        console.log(c.green("  ✓ Session stopped"));
        console.log(`  Session: ${c.cyan(id)}`);
        console.log("");
      });
      return;
    }

    throw new Error("Usage: oppi session list|get|create|send|read|events|trace|stop");
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

async function createSession(
  storage: Storage,
  flags: Record<string, string>,
  jsonOutput: boolean,
  hostResolvers: LocalApiHostResolvers,
): Promise<void> {
  const workspaceRef = flags.workspace?.trim();
  const promptText = flags.prompt;
  if (!workspaceRef || promptText === undefined || promptText.trim() === "") {
    const message = "--workspace and --prompt are required";
    if (jsonOutput) writeJsonEnvelope({ ok: false, error: { message } });
    else {
      console.log(c.red(`  Error: ${message}`));
      console.log(c.dim("  Usage: oppi session create --workspace <id> --prompt <text> [--json]"));
    }
    process.exitCode = 1;
    return;
  }
  const workspaceId = await resolveWorkspaceIdForCli(storage, workspaceRef, hostResolvers);
  const savedAgent = savedAgentReference(flags.agent);
  const result = savedAgent
    ? await localApiRequest<{ session: Session; receipt?: Record<string, unknown> }>(
        storage,
        `/agents/${encodeURIComponent(savedAgent)}/sessions`,
        {
          method: "POST",
          body: {
            prompt: { text: promptText },
            target: {
              workspaceId,
              ...(flags.worktree ? { worktreeId: flags.worktree } : {}),
            },
            ...(flags.name ? { sessionName: flags.name } : {}),
            ...(flags.model || flags.thinking
              ? {
                  overrides: {
                    ...(flags.model ? { model: flags.model } : {}),
                    ...(flags.thinking ? { thinkingLevel: flags.thinking } : {}),
                  },
                }
              : {}),
            ...(flags["idempotency-key"] ? { idempotencyKey: flags["idempotency-key"] } : {}),
          },
        },
        hostResolvers,
      )
    : await localApiRequest<{ session: Session; prompted?: boolean }>(
        storage,
        `/workspaces/${encodeURIComponent(workspaceId)}/sessions`,
        {
          method: "POST",
          body: {
            prompt: promptText,
            ...(flags.name ? { name: flags.name } : {}),
            ...(flags.model ? { model: flags.model } : {}),
            ...(flags.thinking ? { thinking: flags.thinking } : {}),
            ...(flags.worktree ? { worktreeId: flags.worktree } : {}),
            ...(flags["idempotency-key"] ? { launchIdempotencyKey: flags["idempotency-key"] } : {}),
          },
        },
        hostResolvers,
      );
  if (jsonOutput) {
    writeJsonEnvelope({ ok: true, data: result as unknown as Record<string, unknown> });
    return;
  }

  console.log(c.green("  ✓ Session created"));
  console.log(`  Workspace: ${c.cyan(workspaceId)}`);
  console.log(`  Session:   ${c.cyan(result.session.id)}`);
  console.log("");
  console.log(c.bold("  Next commands:"));
  console.log(`    ${c.dim(`oppi session read ${result.session.id}`)}`);
  console.log(`    ${c.dim(`oppi session events ${result.session.id}`)}`);
  console.log(`    ${c.dim(`oppi session send ${result.session.id} --text "..."`)}`);
  console.log("");
}

function requirePositional(positional: string[], message: string): string {
  const value = positional[0]?.trim();
  if (!value) throw new Error(message);
  return value;
}

function querySuffix(params: URLSearchParams): string {
  const query = params.toString();
  return query ? `?${query}` : "";
}

function savedAgentReference(agent: string | undefined): string | undefined {
  const normalized = agent?.trim();
  if (!normalized || normalized === "default" || normalized === "workspace_default")
    return undefined;
  return normalized;
}

function eventText(event: SessionTraceEvent): string {
  if (typeof event.text === "string") return event.text;
  if (typeof event.message === "string") return event.message;
  return "";
}
