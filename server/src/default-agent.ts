import type { AgentDefinition } from "./agent-launch-service.js";
import { DEFAULT_ICON_CHOICE } from "./icon-choice.js";
import { getOppiDocsPath } from "./oppi-docs.js";

export const DEFAULT_AGENT_ID = "oppi-default-agent";
export const DEFAULT_AGENT_ALIAS = "oppi";
export const DEFAULT_AGENT_DEFAULT_NAME = "Oppi";
/** Control tools: Oppi state/clarification plus Pi's stock existing-file tools. */
export const DEFAULT_AGENT_TOOL_NAMES = ["oppi", "ask", "read", "edit"] as const;

export const DEFAULT_AGENT_DEFINITION: AgentDefinition = {
  name: DEFAULT_AGENT_DEFAULT_NAME,
  icon: DEFAULT_ICON_CHOICE,
  description:
    "Manage Oppi workspaces, Agents, Skills, schedules, and sessions through the built-in oppi tool. Destructive actions need approval.",
  resources: {
    noContextFiles: true,
  },
  sessionDefaults: {
    noTools: "builtin",
    tools: [...DEFAULT_AGENT_TOOL_NAMES],
  },
};

const DEFAULT_AGENT_CUSTOMIZATION_KEYS = new Set([
  // Name may appear in edit bodies; safety defaults always force Oppi.
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
      throw new Error(`Oppi agent customization cannot include ${key}`);
    }
  }

  if (patch.sessionDefaults !== undefined && patch.sessionDefaults !== null) {
    if (!isRecord(patch.sessionDefaults)) {
      throw new Error("sessionDefaults must be an object");
    }
    for (const key of Object.keys(patch.sessionDefaults)) {
      if (!DEFAULT_AGENT_SESSION_DEFAULT_KEYS.has(key)) {
        throw new Error(`Oppi agent customization cannot include sessionDefaults.${key}`);
      }
    }
  }
}

export function applyDefaultAgentSafetyDefaults(definition: AgentDefinition): AgentDefinition {
  const sessionDefaults = definition.sessionDefaults ?? {};
  return {
    // Shipped control identity always presents as Oppi.
    name: DEFAULT_AGENT_DEFAULT_NAME,
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

/**
 * Minimal control prompt modeled on Pi's default system prompt:
 * short identity, tool list, a few guidelines, and pointers to shipped docs.
 * CLI details come from `oppi help`, not from a long baked-in manual.
 */
export function buildDefaultAgentSystemPrompt(options?: {
  docsPath?: string;
  includeDocs?: boolean;
}): string {
  const docsPath =
    options?.includeDocs === false ? undefined : (options?.docsPath ?? getOppiDocsPath());
  const lines = [
    "You are Oppi, the control agent for this Oppi server. Help users manage workspaces, Agents, Skills, schedules, and sessions.",
    "",
    "Available tools:",
    "- oppi: Run one exposed Oppi CLI command as JSON under the server approval policy.",
    "- ask: Ask structured clarifying questions when preferences or tradeoffs are ambiguous.",
    "- read: Read any host-readable file with Pi's stock file reader.",
    "- edit: Edit any existing host-writable file with Pi's stock exact-replacement tool.",
    "",
    "Guidelines:",
    "- Discover CLI usage with oppi help, nested help topics, and --help. Do not guess flags or subcommands.",
    "- Inspect current state with oppi before asking about discoverable facts or making changes.",
    "- Destructive actions need approval. Do not invent an extra approve step in chat.",
    "- Call ask at most once per turn, only for unresolved preferences or tradeoffs.",
    "- Be concise.",
  ];

  if (docsPath) {
    lines.push(
      "",
      "Oppi documentation (read when you need operator detail):",
      `- Docs directory: ${docsPath}`,
      `- Server configuration (ASR, TTS, config CLI): ${docsPath}/server-configuration.md`,
      `- Extensions: ${docsPath}/extensions.md`,
      `- Onboarding and pairing: ${docsPath}/onboarding.md`,
      "- Prefer these operator docs over architecture internals. Read the relevant doc fully and follow .md cross-references.",
    );
  }

  return lines.join("\n");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}
