import type { AgentDefinition } from "./agent-launch-service.js";

export const DEFAULT_AGENT_ID = "oppi-default-agent";
export const DEFAULT_AGENT_ALIAS = "default";
export const DEFAULT_AGENT_DEFAULT_NAME = "Default Agent";

export const DEFAULT_AGENT_DEFINITION: AgentDefinition = {
  name: DEFAULT_AGENT_DEFAULT_NAME,
  description:
    "Manage Oppi workspaces, Agents, schedules, and sessions with explicit approval before changes.",
  resources: {
    noContextFiles: true,
  },
  sessionDefaults: {
    noTools: "builtin",
    tools: ["oppi"],
  },
};

const DEFAULT_AGENT_CUSTOMIZATION_KEYS = new Set([
  "name",
  "icon",
  "description",
  "instructions",
  "sessionDefaults",
]);
const DEFAULT_AGENT_SESSION_DEFAULT_KEYS = new Set(["model", "thinkingLevel"]);

export function isDefaultAgentId(id: string): boolean {
  return id === DEFAULT_AGENT_ID;
}

export function isDefaultAgentReference(reference: string): boolean {
  const normalized = reference.trim().toLowerCase();
  return normalized === DEFAULT_AGENT_ALIAS || normalized === DEFAULT_AGENT_ID;
}

export function isDefaultAgentReservedName(name: string): boolean {
  const normalized = name.trim().toLowerCase();
  return (
    normalized === DEFAULT_AGENT_DEFAULT_NAME.toLowerCase() || normalized === DEFAULT_AGENT_ALIAS
  );
}

export function assertDefaultAgentCustomizationPatch(patch: unknown): void {
  if (!isRecord(patch)) {
    throw new Error("Agent update must be an object");
  }

  for (const key of Object.keys(patch)) {
    if (!DEFAULT_AGENT_CUSTOMIZATION_KEYS.has(key)) {
      throw new Error(`Default Agent customization cannot include ${key}`);
    }
  }

  if (patch.sessionDefaults !== undefined && patch.sessionDefaults !== null) {
    if (!isRecord(patch.sessionDefaults)) {
      throw new Error("sessionDefaults must be an object");
    }
    for (const key of Object.keys(patch.sessionDefaults)) {
      if (!DEFAULT_AGENT_SESSION_DEFAULT_KEYS.has(key)) {
        throw new Error(`Default Agent customization cannot include sessionDefaults.${key}`);
      }
    }
  }
}

export function applyDefaultAgentSafetyDefaults(definition: AgentDefinition): AgentDefinition {
  const sessionDefaults = definition.sessionDefaults ?? {};
  return {
    name: definition.name,
    ...(definition.icon !== undefined ? { icon: definition.icon } : {}),
    ...(definition.description !== undefined ? { description: definition.description } : {}),
    ...(definition.instructions !== undefined ? { instructions: definition.instructions } : {}),
    resources: { ...DEFAULT_AGENT_DEFINITION.resources },
    sessionDefaults: {
      ...DEFAULT_AGENT_DEFINITION.sessionDefaults,
      ...(sessionDefaults.model !== undefined ? { model: sessionDefaults.model } : {}),
      ...(sessionDefaults.thinkingLevel !== undefined
        ? { thinkingLevel: sessionDefaults.thinkingLevel }
        : {}),
    },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}
