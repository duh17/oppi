/* eslint-disable no-console */
import * as c from "../../ansi.js";
import { formatIconChoice } from "../../icon-choice.js";
import type { IconChoice } from "../../types.js";
import type { LocalApiConnection } from "../local-api-client.js";
import { createLocalApiCommandContext } from "../command-support.js";
import { readDefinitionInput } from "../definition-input.js";
import {
  applySessionDefaultFlags,
  hasSessionDefaultFlags,
  resolveNoToolsFlag,
} from "../launch-flags.js";
import { resolveModelFlagForCli } from "../model-resolution.js";
import {
  codeValue,
  printDetails,
  printList,
  printNextCommands,
  setCapturedCliExitCode,
  writeJsonEnvelope,
} from "../output.js";
import { apiStatus } from "../resources.js";

const AGENT_VERSION_CONFLICT_CODE = "AGENT_VERSION_CONFLICT";

type AgentRow = {
  id?: string;
  name?: string;
  icon?: IconChoice;
  status?: string;
  version?: number;
  definition?: unknown;
};

export async function cmdAgent(
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
      const result = await call<Record<string, unknown>>("/agents");
      output(result, () => {
        const agents = Array.isArray(result.agents) ? (result.agents as AgentRow[]) : [];
        printList(
          `Agents (${agents.length})`,
          agents.map((agent) => ({
            id: agent.id ?? "?",
            status: agent.status ?? "?",
            title: agent.name ?? "(unnamed)",
            meta: [
              agent.version !== undefined ? `v${agent.version}` : "?",
              ...(agent.icon ? [`icon ${formatIconChoice(agent.icon)}`] : []),
            ],
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
      resolveNoToolsFlag(flags);
      const definition = applySessionDefaultFlags(
        readDefinitionInput(flags),
        flags,
        await resolveModelFlagForCli(storage, flags.model),
      );
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
      resolveNoToolsFlag(flags);
      const expectedVersion = parseExpectedAgentVersionFlag(flags);
      const definition = applySessionDefaultFlags(
        readDefinitionInput(flags, {
          required: !hasSessionDefaultFlags(flags),
          update: true,
        }),
        flags,
        await resolveModelFlagForCli(storage, flags.model),
      );
      if (Object.keys(definition).length === 0) {
        throw new Error("definition update must not be empty");
      }
      const query =
        expectedVersion === undefined
          ? ""
          : `?expectedVersion=${encodeURIComponent(expectedVersion)}`;
      const result = await call<Record<string, unknown>>(
        `/agents/${encodeURIComponent(reference)}${query}`,
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
      writeJsonEnvelope({
        ok: false,
        error: {
          message,
          ...(status ? { status } : {}),
          ...agentErrorDetails(error),
        },
      });
      setCapturedCliExitCode(1);
      return;
    }
    console.log(c.red(`  Error: ${message}`));
    process.exit(1);
  }
}

type AgentErrorDetails = {
  code?: string;
  expectedVersion?: number;
  currentVersion?: number;
};

function parseExpectedAgentVersionFlag(flags: Record<string, string>): number | undefined {
  if (Object.keys(flags).some((key) => key.startsWith("expected-version="))) {
    throw new Error("Use --expected-version <version>; equals form is not supported");
  }
  const value = flags["expected-version"];
  if (value === undefined) return undefined;
  if (!/^[1-9]\d*$/.test(value)) {
    throw new Error("--expected-version must be a positive safe integer");
  }
  const version = Number(value);
  if (!Number.isSafeInteger(version)) {
    throw new Error("--expected-version must be a positive safe integer");
  }
  return version;
}

function agentErrorDetails(error: unknown): AgentErrorDetails {
  const record = isRecord(error) ? error : undefined;
  if (record?.code !== AGENT_VERSION_CONFLICT_CODE) return {};
  const expectedVersion = positiveVersion(record.expectedVersion);
  const currentVersion = positiveVersion(record.currentVersion);
  return {
    code: AGENT_VERSION_CONFLICT_CODE,
    ...(expectedVersion !== undefined ? { expectedVersion } : {}),
    ...(currentVersion !== undefined ? { currentVersion } : {}),
  };
}

function positiveVersion(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0 ? value : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}
