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
import { apiStatus } from "../resources.js";

type AgentRow = {
  id?: string;
  name?: string;
  status?: string;
  version?: number;
  definition?: unknown;
};

export async function cmdAgent(
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
      const result = await call<Record<string, unknown>>("/agents");
      output(result, () => {
        const agents = Array.isArray(result.agents) ? result.agents : [];
        console.log(c.bold(`  Agents (${agents.length})`));
        for (const agent of agents as AgentRow[]) {
          console.log(
            `  ${c.cyan(agent.id ?? "?")}  ${agent.status ?? "?"}  v${agent.version ?? "?"}  ${agent.name ?? "(unnamed)"}`,
          );
        }
        console.log("");
      });
      return;
    }

    if (mode === "get") {
      const reference = positional[0]?.trim();
      if (!reference) throw new Error("agent id or name is required");
      const result = await call<Record<string, unknown>>(
        `/agents/${encodeURIComponent(reference)}`,
      );
      output(result, () => {
        const agent = result.agent as AgentRow | undefined;
        console.log(c.green("  Agent"));
        console.log(`  ID:      ${c.cyan(agent?.id ?? reference)}`);
        console.log(`  Name:    ${agent?.name ?? "(unnamed)"}`);
        console.log(`  Status:  ${agent?.status ?? "unknown"}`);
        console.log(`  Version: ${agent?.version ?? "?"}`);
        console.log("");
      });
      return;
    }

    if (mode === "create") {
      const definition = readDefinition(flags.definition);
      if (flags.name) definition.name = flags.name;
      if (!definition.name) throw new Error("--name or definition.name is required");
      const result = await call<Record<string, unknown>>("/agents", {
        method: "POST",
        body: definition,
      });
      output(result, () => {
        const agent = result.agent as AgentRow | undefined;
        console.log(c.green("  ✓ Agent created"));
        console.log(`  Agent: ${c.cyan(agent?.id ?? "?")}`);
        console.log(`  Name:  ${agent?.name ?? definition.name}`);
        console.log("");
        console.log(c.bold("  Next commands:"));
        console.log(
          `    ${c.dim(`oppi session create --agent ${agent?.id ?? "<agent>"} --workspace <workspace> --prompt "..."`)}`,
        );
        console.log("");
      });
      return;
    }

    if (mode === "update") {
      const reference = positional[0]?.trim();
      if (!reference) throw new Error("agent id or name is required");
      const definition = readDefinition(flags.definition, { required: true });
      const result = await call<Record<string, unknown>>(
        `/agents/${encodeURIComponent(reference)}`,
        {
          method: "PATCH",
          body: definition,
        },
      );
      output(result, () => {
        const agent = result.agent as AgentRow | undefined;
        console.log(c.green("  ✓ Agent updated"));
        console.log(`  Agent:  ${c.cyan(agent?.id ?? reference)}`);
        console.log(`  Version: ${agent?.version ?? "?"}`);
        console.log("");
      });
      return;
    }

    if (mode === "archive") {
      const reference = positional[0]?.trim();
      if (!reference) throw new Error("agent id or name is required");
      const result = await call<Record<string, unknown>>(
        `/agents/${encodeURIComponent(reference)}`,
        {
          method: "DELETE",
        },
      );
      output(result, () => {
        const agent = result.agent as AgentRow | undefined;
        console.log(c.green("  ✓ Agent archived"));
        console.log(`  Agent: ${c.cyan(agent?.id ?? reference)}`);
        console.log("");
      });
      return;
    }

    throw new Error("Usage: oppi agent list|get|create|update|archive");
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    const status = apiStatus(error);
    if (jsonOutput) {
      writeJsonEnvelope({ ok: false, error: { message, ...(status ? { status } : {}) } });
      process.exitCode = 1;
      return;
    }
    console.log(c.red(`  Error: ${message}`));
    process.exit(1);
  }
}

function readDefinition(
  path: string | undefined,
  options: { required?: boolean } = {},
): Record<string, unknown> {
  if (!path) {
    if (options.required) throw new Error("--definition is required");
    return {};
  }
  const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("definition must be a JSON object");
  }
  return parsed as Record<string, unknown>;
}
