import {
  defineDoc,
  type AgentChange,
  type Extension,
  type ModelRef,
  type ToolRegistration,
} from "@earendil-works/pi-durable";

import { AgentConfigurationError } from "./agent-launch-errors.js";
import type { AgentDefinition } from "./agent-launch-service.js";
import type { LoadedDurableExtension } from "./durable-extension-loader.js";
import { DURABLE_MCP_EXTENSION_PREFIX } from "./durable-mcp.js";
import { BUILTIN_EXTENSION_PATH_PREFIX } from "./host-mcp-extensions.js";
import type { ThinkingLevel } from "./thinking-levels.js";
import type { Session } from "./types.js";

type DurableToolPolicy = NonNullable<NonNullable<Session["launch"]>["tools"]>;

/** The AGENTS files and Skills a saved Agent selects; Pi discovery when unset. */
export type DurableAgentResources = {
  skillPaths?: string[];
  agentsFiles?: Array<{ path: string; content: string }>;
  noContextFiles?: boolean;
};

/**
 * What a conversation was launched as, read when it attaches instead of the saved Agent:
 * after launch nothing reads the definition again, so editing an Agent changes later launches,
 * not running sessions. A child starts with a copy of its parent's and keeps it for life.
 */
export type OppiAgentState = {
  /** The saved Agent, as it was at launch; for the session row's name and icon. */
  agent?: {
    id: string;
    version: number;
    name: string;
    icon?: NonNullable<AgentDefinition["icon"]>;
    description?: string;
  };
  /** May use `subagent spawn`: a top-level session, or a child granted `allowNestedDelegation`. */
  spawn: boolean;
  /** Holds the `allowNestedDelegation` grant; it passes down to every child. */
  grant: boolean;
  /** Selected AGENTS files and Skills for the project-context sections. */
  resources?: DurableAgentResources;
  /** False when the Agent's instructions replace the prompt: no `project_context` section. */
  projectContext?: false;
  /** An exact Extension selection: Pi package durable extensions by name, and MCP or not. */
  extensions?: { packages: string[]; mcp: boolean };
  /** The tool policy, also applied to tools added when the session attaches again. */
  tools?: DurableToolPolicy;
};

export const OppiAgentDoc = defineDoc<OppiAgentState>({
  kind: "oppi.agent",
  version: 1,
  scope: "conversation",
  history: "latest",
  // A fork is launched as what its source was.
  fork: "current",
  initial: () => ({ spawn: true, grant: false }),
});

/** A resolved agent: always an exact extension and tool selection. */
type DurableAgentChange = AgentChange & {
  readonly extensions: readonly Extension[];
  readonly tools: readonly ToolRegistration[];
};

/** A saved Agent pinned to the version a launch uses. */
export interface SavedAgent {
  id: string;
  version: number;
  definition: AgentDefinition;
}

const DURABLE_DEFAULT_INSTRUCTIONS =
  "You are an expert coding assistant. Use the available tools to inspect and change files. Be concise.";

/** The `instructions` of a durable session: Oppi's default or the Agent's replacement, then cwd and appends. */
function durableInstructions(options: {
  cwd: string;
  workspacePrompt?: string;
  instructions?: AgentDefinition["instructions"];
}): string {
  const { cwd, workspacePrompt, instructions } = options;
  const append = [workspacePrompt, instructions?.mode === "append" ? instructions.text : undefined]
    .filter(Boolean)
    .join("\n\n");
  return [
    instructions?.mode === "replace" ? instructions.text : DURABLE_DEFAULT_INSTRUCTIONS,
    `Working directory: ${cwd}`,
    append,
  ]
    .filter(Boolean)
    .join("\n\n");
}

export function toolAllowed(policy: DurableToolPolicy | undefined, name: string): boolean {
  return (
    !policy?.noTools &&
    (!policy?.allowed || policy.allowed.includes(name)) &&
    !policy?.excluded?.includes(name)
  );
}

/**
 * The durable extensions a saved Agent's exact Extension selection names. `builtin:mcp` is the
 * session's own MCP extension; any other ID must belong to a Pi package whose durable entry is
 * loaded for this runtime. Fails closed with `agent_extensions_unavailable`, naming each ID that
 * has no durable entry, rather than starting without it.
 */
export function resolveDurableExtensionSelection(
  extensionIds: readonly string[],
  loaded: readonly LoadedDurableExtension[],
  runtime: "host" | "sandbox",
): { packages: LoadedDurableExtension[]; mcp: boolean } {
  const packages: LoadedDurableExtension[] = [];
  const missing: string[] = [];
  let mcp = false;
  for (const id of new Set(extensionIds)) {
    if (id === `${BUILTIN_EXTENSION_PATH_PREFIX}mcp`) {
      mcp = true;
      continue;
    }
    const found = loaded.find((candidate) => candidate.extensionIds.includes(id));
    if (!found || !found.runtimes.includes(runtime)) {
      missing.push(id);
      continue;
    }
    if (!packages.includes(found)) packages.push(found);
  }
  if (missing.length > 0)
    throw new AgentConfigurationError(
      "agent_extensions_unavailable",
      { unavailableExtensions: missing },
      `Selected Agent Extension has no durable entry for a ${runtime} session: ${missing.join(", ")}`,
    );
  return { packages, mcp };
}

interface DurableAgentInput {
  /** The saved Agent to launch as; without one a child is a copy of `inherited`. */
  saved?: SavedAgent;
  /** Explicit choices; they override the saved Agent's. */
  model?: ModelRef;
  thinkingLevel?: ThinkingLevel;
  /** An explicit tool policy (a top-level launch's); overrides the saved Agent's. */
  policy?: DurableToolPolicy;
  /** The parent's document, for a child without a saved Agent. */
  inherited?: OppiAgentState;
  runtime: "host" | "sandbox";
  /**
   * The extensions to start from: the parent's for a child, Oppi's defaults (built-ins and every
   * Pi package durable extension of the runtime) for a top-level session. MCP extensions are
   * per session and are dropped; the session attaches its own.
   */
  base: readonly Extension[];
  /** Every loaded Pi package durable extension. */
  loaded: readonly LoadedDurableExtension[];
  /** Oppi's extension that offers `subagent`. */
  sessions: Extension;
  spawn: boolean;
  grant: boolean;
  /** Where the instructions come from; unset keeps the base agent's (a child without an Agent). */
  instructions?: { cwd: string; workspacePrompt?: string };
}

/**
 * The one mapping from a saved Agent (or none) to pi-durable's `AgentChange` plus the
 * conversation's `oppi.agent` document. A top-level launch commits it when it creates its
 * conversation; `subagent spawn` commits it with the child conversation.
 *
 * | AgentDefinition                         | AgentChange / document                          |
 * | `sessionDefaults.model`, `thinkingLevel` | `model`, `thinkingLevel` (explicit ones win)     |
 * | `sessionDefaults.tools/excludeTools/noTools` | `tools`, and `oppi.agent.tools`             |
 * | `resources.extensionIds`                | `extensions`, and `oppi.agent.extensions`        |
 * | `resources.skillPaths/agentsFiles/noContextFiles` | `oppi.agent.resources`                 |
 * | `instructions`                          | `instructions`; replace sets `projectContext: false` |
 * | `name`, `icon`, `description`, id, version | `oppi.agent.agent`                            |
 */
export function resolveDurableAgent(input: DurableAgentInput): {
  change: DurableAgentChange;
  doc: OppiAgentState;
} {
  const { saved, runtime, loaded } = input;
  const definition = saved?.definition;
  const packageNames = new Set(loaded.map((entry) => entry.extension.name));
  const kept = input.base.filter(
    (extension) =>
      !extension.name.startsWith(DURABLE_MCP_EXTENSION_PREFIX) &&
      extension.name !== input.sessions.name &&
      // A saved Agent picks its own packages; a copy keeps the parent's.
      !(saved && packageNames.has(extension.name)),
  );
  const extensionIds = definition?.resources?.extensionIds;
  const selection =
    extensionIds === undefined
      ? undefined
      : resolveDurableExtensionSelection(extensionIds, loaded, runtime);
  const packages = !saved
    ? []
    : (selection?.packages ?? loaded.filter((entry) => entry.runtimes.includes(runtime))).map(
        (entry) => entry.extension,
      );
  const extensions = [...kept, ...(input.spawn ? [input.sessions] : []), ...packages];

  const policy: DurableToolPolicy | undefined =
    input.policy ??
    (saved ? savedPolicy(definition?.sessionDefaults) : undefined) ??
    input.inherited?.tools;
  const tools: ToolRegistration[] = extensions
    .flatMap((extension) => extension.tools ?? [])
    .filter((tool) => toolAllowed(policy, tool.name));

  const preset = definition?.sessionDefaults;
  const thinkingLevel = input.thinkingLevel ?? preset?.thinkingLevel;
  const change: DurableAgentChange = {
    ...(input.model ? { model: input.model } : {}),
    ...(thinkingLevel ? { thinkingLevel } : {}),
    extensions,
    tools,
    ...(input.instructions
      ? {
          instructions: durableInstructions({
            ...input.instructions,
            ...(definition?.instructions ? { instructions: definition.instructions } : {}),
          }),
        }
      : {}),
  };

  const resources = definition?.resources ? agentResources(definition.resources) : undefined;
  const doc: OppiAgentState = saved
    ? {
        agent: {
          id: saved.id,
          version: saved.version,
          name: saved.definition.name,
          ...(saved.definition.icon ? { icon: saved.definition.icon } : {}),
          ...(saved.definition.description ? { description: saved.definition.description } : {}),
        },
        spawn: input.spawn,
        grant: input.grant,
        ...(resources ? { resources } : {}),
        ...(saved.definition.instructions?.mode === "replace"
          ? { projectContext: false as const }
          : {}),
        ...(selection
          ? {
              extensions: {
                packages: selection.packages.map((entry) => entry.extension.name),
                mcp: selection.mcp,
              },
            }
          : {}),
        ...(policy ? { tools: policy } : {}),
      }
    : {
        // A copy of the parent, with its own delegation.
        ...structuredClone(input.inherited ?? {}),
        spawn: input.spawn,
        grant: input.grant,
        ...(policy ? { tools: policy } : {}),
      };
  return { change, doc };
}

function savedPolicy(defaults: AgentDefinition["sessionDefaults"]): DurableToolPolicy | undefined {
  if (!defaults?.tools && !defaults?.excludeTools && !defaults?.noTools) return undefined;
  return {
    ...(defaults.tools ? { allowed: defaults.tools } : {}),
    ...(defaults.excludeTools ? { excluded: defaults.excludeTools } : {}),
    ...(defaults.noTools ? { noTools: defaults.noTools } : {}),
  };
}

function agentResources(
  resources: NonNullable<AgentDefinition["resources"]>,
): DurableAgentResources | undefined {
  const { skillPaths, agentsFiles, noContextFiles } = resources;
  if (skillPaths === undefined && agentsFiles === undefined && noContextFiles === undefined)
    return undefined;
  return {
    ...(skillPaths !== undefined ? { skillPaths } : {}),
    ...(agentsFiles !== undefined ? { agentsFiles } : {}),
    ...(noContextFiles !== undefined ? { noContextFiles } : {}),
  };
}
