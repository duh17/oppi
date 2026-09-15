/* eslint-disable no-console */
import { readFileSync } from "node:fs";

import * as c from "../../ansi.js";
import { formatIconChoice } from "../../icon-choice.js";
import type { IconChoice } from "../../types.js";
import type { LocalApiConnection } from "../local-api-client.js";
import { createLocalApiCommandContext } from "../command-support.js";
import { readDefinitionInput } from "../definition-input.js";
import { iconChoiceFromFlag } from "../icon-flag.js";
import {
  applySessionDefaultFlags,
  hasAgentDefinitionFlags,
  parseCsvList,
  resolveNoToolsFlag,
} from "../launch-flags.js";
import { resolveModelFlagForCli } from "../model-resolution.js";
import {
  codeValue,
  printDetails,
  printList,
  printNextCommands,
  setCapturedCliExitCode,
  writeHumanLine,
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
        writeHumanLine(`  For the full definition, run \`oppi agent get ${reference} --json\`.`);
        writeHumanLine("");
      });
      return;
    }

    if (mode === "create") {
      resolveNoToolsFlag(flags);
      const definition = applyAgentFieldFlags(
        applySessionDefaultFlags(
          readDefinitionInput(flags),
          flags,
          await resolveModelFlagForCli(storage, flags.model),
        ),
        flags,
        { update: false },
      );
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
      const definition = applyAgentFieldFlags(
        applySessionDefaultFlags(
          readDefinitionInput(flags, {
            required: !hasAgentDefinitionFlags(flags),
            update: true,
          }),
          flags,
          await resolveModelFlagForCli(storage, flags.model),
        ),
        flags,
        { update: true },
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

const AGENT_CLEAR_FLAGS = [
  "clear-description",
  "clear-icon",
  "clear-instructions",
  "clear-skills",
  "clear-extensions",
  "clear-allowed-workspaces",
  "clear-required-runtime",
] as const;

const AGENT_VALUE_CLEAR_TWINS: Array<{ values: string[]; clear: string }> = [
  { values: ["description"], clear: "clear-description" },
  { values: ["icon"], clear: "clear-icon" },
  {
    values: ["instructions", "instructions-file", "instructions-mode"],
    clear: "clear-instructions",
  },
  { values: ["skills"], clear: "clear-skills" },
  { values: ["extensions"], clear: "clear-extensions" },
  { values: ["allowed-workspaces"], clear: "clear-allowed-workspaces" },
  { values: ["required-runtime"], clear: "clear-required-runtime" },
];

function hasFlag(flags: Record<string, string>, name: string): boolean {
  return Object.hasOwn(flags, name);
}

function applyAgentFieldFlags(
  definition: Record<string, unknown>,
  flags: Record<string, string>,
  options: { update: boolean },
): Record<string, unknown> {
  if (!options.update) {
    for (const name of AGENT_CLEAR_FLAGS) {
      if (hasFlag(flags, name)) {
        throw new Error(`--${name} is only valid on agent update`);
      }
    }
  }
  for (const twin of AGENT_VALUE_CLEAR_TWINS) {
    const present = twin.values.filter((name) => hasFlag(flags, name));
    if (present.length > 0 && hasFlag(flags, twin.clear)) {
      throw new Error(`--${present[0]} and --${twin.clear} cannot be used together`);
    }
  }

  const next = { ...definition };
  if (hasFlag(flags, "name")) next.name = flags.name;
  if (hasFlag(flags, "description")) next.description = flags.description;
  if (hasFlag(flags, "clear-description")) next.description = null;
  if (hasFlag(flags, "icon")) next.icon = iconChoiceFromFlag(flags.icon ?? "");
  if (hasFlag(flags, "clear-icon")) next.icon = null;
  applyInstructionFlags(next, flags);
  applyResourceFlags(next, flags);
  applyLaunchConstraintFlags(next, flags);
  return next;
}

function applyInstructionFlags(
  definition: Record<string, unknown>,
  flags: Record<string, string>,
): void {
  if (hasFlag(flags, "clear-instructions")) {
    definition.instructions = null;
    return;
  }

  const hasText = hasFlag(flags, "instructions");
  const hasFile = hasFlag(flags, "instructions-file");
  const hasMode = hasFlag(flags, "instructions-mode");
  if (hasText && hasFile) {
    throw new Error("--instructions and --instructions-file cannot be used together");
  }

  let text: string | undefined;
  if (hasText) text = flags.instructions ?? "";
  if (hasFile) {
    const path = flags["instructions-file"]?.trim();
    if (!path) throw new Error("--instructions-file must be a non-empty file path");
    try {
      text = readFileSync(path, "utf8");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`--instructions-file must be a readable file: ${message}`, { cause: error });
    }
  }

  if (hasMode) {
    const mode = flags["instructions-mode"];
    if (mode !== "append" && mode !== "replace") {
      throw new Error("--instructions-mode must be append or replace");
    }
    const resolvedText = text ?? instructionTextFromDefinition(definition);
    if (resolvedText === undefined) {
      throw new Error(
        "--instructions-mode requires --instructions, --instructions-file, or instructions.text in the definition JSON",
      );
    }
    definition.instructions = { mode, text: resolvedText };
    return;
  }

  if (text !== undefined) {
    definition.instructions = {
      mode: instructionModeFromDefinition(definition) ?? "append",
      text,
    };
  }
}

function instructionTextFromDefinition(definition: Record<string, unknown>): string | undefined {
  if (!isRecord(definition.instructions)) return undefined;
  const text = definition.instructions.text;
  return typeof text === "string" ? text : undefined;
}

function instructionModeFromDefinition(
  definition: Record<string, unknown>,
): "append" | "replace" | undefined {
  if (!isRecord(definition.instructions)) return undefined;
  const mode = definition.instructions.mode;
  return mode === "append" || mode === "replace" ? mode : undefined;
}

function applyResourceFlags(
  definition: Record<string, unknown>,
  flags: Record<string, string>,
): void {
  if (hasFlag(flags, "skills")) {
    overlayNested(definition, "resources", "skillPaths", parseCsvList(flags.skills ?? ""));
  }
  if (hasFlag(flags, "clear-skills")) {
    overlayNested(definition, "resources", "skillPaths", null);
  }
  if (hasFlag(flags, "extensions")) {
    overlayNested(definition, "resources", "extensionIds", parseCsvList(flags.extensions ?? ""));
  }
  if (hasFlag(flags, "clear-extensions")) {
    overlayNested(definition, "resources", "extensionIds", null);
  }
}

function applyLaunchConstraintFlags(
  definition: Record<string, unknown>,
  flags: Record<string, string>,
): void {
  if (hasFlag(flags, "allowed-workspaces")) {
    const allowedWorkspaceIds = parseCsvList(flags["allowed-workspaces"] ?? "");
    if (allowedWorkspaceIds.length === 0) {
      throw new Error("--allowed-workspaces must not be empty");
    }
    overlayNested(definition, "launchConstraints", "allowedWorkspaceIds", allowedWorkspaceIds);
  }
  if (hasFlag(flags, "clear-allowed-workspaces")) {
    overlayNested(definition, "launchConstraints", "allowedWorkspaceIds", null);
  }
  if (hasFlag(flags, "required-runtime")) {
    const requiredRuntime = flags["required-runtime"];
    if (requiredRuntime !== "host" && requiredRuntime !== "sandbox") {
      throw new Error("--required-runtime must be host or sandbox");
    }
    overlayNested(definition, "launchConstraints", "requiredRuntime", requiredRuntime);
  }
  if (hasFlag(flags, "clear-required-runtime")) {
    overlayNested(definition, "launchConstraints", "requiredRuntime", null);
  }
}

function overlayNested(
  definition: Record<string, unknown>,
  parentKey: string,
  nestedKey: string,
  value: unknown,
): void {
  if (definition[parentKey] === null) {
    throw new Error(
      `cannot overlay ${parentKey}.${nestedKey} because ${parentKey} is null in the definition JSON`,
    );
  }
  const current = isRecord(definition[parentKey]) ? { ...definition[parentKey] } : {};
  current[nestedKey] = value;
  definition[parentKey] = current;
}
