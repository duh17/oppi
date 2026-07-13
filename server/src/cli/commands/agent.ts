/* eslint-disable no-console */
import { readFileSync } from "node:fs";

import * as c from "../../ansi.js";
import type { LocalApiConnection, LocalApiHostResolvers } from "../local-api-client.js";
import { createLocalApiCommandContext } from "../command-support.js";
import {
  codeValue,
  printDetails,
  printList,
  printNextCommands,
  writeJsonEnvelope,
} from "../output.js";
import { apiStatus } from "../resources.js";

type AgentRow = {
  id?: string;
  name?: string;
  status?: string;
  version?: number;
  definition?: unknown;
};

export async function cmdAgent(
  storage: LocalApiConnection,
  action: string | undefined,
  positional: string[],
  flags: Record<string, string>,
  hostResolvers: LocalApiHostResolvers = {},
): Promise<void> {
  const mode = action || "list";
  const jsonOutput = flags.json === "true";

  const { call, output } = createLocalApiCommandContext(storage, jsonOutput, hostResolvers);

  try {
    if (mode === "list") {
      const result = await call<Record<string, unknown>>("/agents");
      output(result, () => {
        const agents = Array.isArray(result.agents) ? (result.agents as AgentRow[]) : [];
        printList(
          `Agents (${agents.length})`,
          agents.map((agent) => ({
            id: agent.id ?? "?",
            status: agent.status ?? "?",
            title: agent.name ?? "(unnamed)",
            meta: [agent.version !== undefined ? `v${agent.version}` : "?"],
          })),
          { empty: "No saved Agents configured." },
        );
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
        printDetails("Agent", [
          ["ID", codeValue(agent?.id ?? reference)],
          ["Name", agent?.name ?? "(unnamed)"],
          ["Status", agent?.status ?? "unknown"],
          ["Version", agent?.version !== undefined ? `v${agent.version}` : "?"],
        ]);
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
        printDetails("✓ Agent created", [
          ["Agent", codeValue(agent?.id ?? "?")],
          ["Name", agent?.name ?? definition.name],
        ]);
        printNextCommands([
          `oppi session create --agent ${agent?.id ?? "<agent>"} --workspace <workspace> --prompt "..."`,
        ]);
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
        printDetails("✓ Agent updated", [
          ["Agent", codeValue(agent?.id ?? reference)],
          ["Version", agent?.version !== undefined ? `v${agent.version}` : "?"],
        ]);
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
        printDetails("✓ Agent archived", [["Agent", codeValue(agent?.id ?? reference)]]);
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
