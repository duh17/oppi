import {
  defineDoc,
  type AgentChange,
  type Extension,
  type ModelRef,
  type ToolRegistration,
} from "@earendil-works/pi-durable";

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
  /**
   * An exact Extension selection: Pi package durable extensions by name, MCP or not, and the
   * names of selected Extensions the session runs without (no durable version), for its warning.
   */
  extensions?: { packages: string[]; mcp: boolean; skipped?: string[] };
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

/**
 * Pi's built-in tool names (`allToolNames`, `pi-coding-agent` dist/core/tools/index.js). Durable
 * offers them through CodingTools (read, bash, edit, write) and the sandbox tools (ls, find, grep).
 */
const PI_BUILTIN_TOOL_NAMES: ReadonlySet<string> = new Set([
  "read",
  "bash",
  "powershell",
  "edit",
  "write",
  "grep",
  "find",
  "ls",
]);

/**
 * Pi's tool policy (`createAgentSession` in `pi-coding-agent` dist/core/sdk.js): an allow list is
 * the enabled set and overrides `noTools`; otherwise `noTools: "all"` enables nothing and
 * `"builtin"` drops only Pi's built-in tools, keeping extension and MCP tools. `excluded` always
 * applies.
 */
export function toolAllowed(policy: DurableToolPolicy | undefined, name: string): boolean {
  if (policy?.excluded?.includes(name)) return false;
  if (policy?.allowed) return policy.allowed.includes(name);
  if (policy?.noTools === "all") return false;
  return !(policy?.noTools === "builtin" && PI_BUILTIN_TOOL_NAMES.has(name));
}

/** What Oppi knows of the classic Extensions a saved Agent selects by ID. */
export interface ClassicExtensionIndex {
  /** IDs of classic Extensions whose durable version Oppi bundles, so every session has it. */
  readonly bundled: ReadonlySet<string>;
  /** A readable name per ID, for the warning about Extensions a session runs without. */
  readonly names: ReadonlyMap<string, string>;
}

const MCP_EXTENSION_ID = `${BUILTIN_EXTENSION_PATH_PREFIX}mcp`;
const TOOL_SEARCH_EXTENSION_ID = `${BUILTIN_EXTENSION_PATH_PREFIX}tool-search`;

/**
 * The durable extensions a saved Agent's exact Extension selection names. `builtin:mcp` is the
 * session's own MCP extension, which brings durable's `tool_search` (it searches MCP tools, so
 * `builtin:tool-search` needs `builtin:mcp`). An ID whose durable version Oppi bundles is in every
 * session already. Any other ID must belong to a Pi package whose durable entry is loaded for this
 * runtime and enabled. The rest, `builtin:codemode` among them (durable sessions have no codemode;
 * MCP tools classic reaches through it load through `tool_search`), are `skipped` by name: the
 * session starts without them and warns.
 */
export function resolveDurableExtensionSelection(
  extensionIds: readonly string[],
  loaded: readonly LoadedDurableExtension[],
  classic: ClassicExtensionIndex,
  runtime: "host" | "sandbox",
  enabled: (name: string) => boolean,
): { packages: LoadedDurableExtension[]; mcp: boolean; skipped: string[] } {
  const ids = new Set(extensionIds);
  const mcp = ids.has(MCP_EXTENSION_ID);
  const packages: LoadedDurableExtension[] = [];
  // By name: two IDs of one package are one skipped Extension.
  const skipped = new Set<string>();
  for (const id of ids) {
    if (id === MCP_EXTENSION_ID || (id === TOOL_SEARCH_EXTENSION_ID && mcp)) continue;
    if (classic.bundled.has(id)) continue;
    const found = loaded.find((candidate) => candidate.extensionIds.includes(id));
    if (found?.runtimes.includes(runtime) && enabled(found.extension.name)) {
      if (!packages.includes(found)) packages.push(found);
      continue;
    }
    skipped.add(
      classic.names.get(id) ??
        (id.startsWith(BUILTIN_EXTENSION_PATH_PREFIX)
          ? id.slice(BUILTIN_EXTENSION_PATH_PREFIX.length)
          : id),
    );
  }
  return { packages, mcp, skipped: [...skipped] };
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
  classic: ClassicExtensionIndex;
  /** Whether the server enables the durable extension of this name (`isExtensionEnabled`). */
  enabled: (name: string) => boolean;
  /** Oppi's extension that offers `subagent`. */
  sessions: Extension;
  spawn: boolean;
  /** Oppi's extension that offers `notify`, and whether this conversation selects it. */
  notify: Extension;
  notifies: boolean;
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
      extension.name !== input.notify.name &&
      // A saved Agent picks its own packages; a copy keeps the parent's.
      !(saved && packageNames.has(extension.name)),
  );
  const extensionIds = definition?.resources?.extensionIds;
  const selection =
    extensionIds === undefined
      ? undefined
      : resolveDurableExtensionSelection(
          extensionIds,
          loaded,
          input.classic,
          runtime,
          input.enabled,
        );
  const packages = !saved
    ? []
    : (selection?.packages ?? loaded.filter((entry) => entry.runtimes.includes(runtime))).map(
        (entry) => entry.extension,
      );
  // A disabled extension leaves every selection, a child's copy of its parent's included.
  const extensions = [
    ...kept,
    ...(input.spawn ? [input.sessions] : []),
    ...(input.notifies ? [input.notify] : []),
    ...packages,
  ].filter((extension) => input.enabled(extension.name));

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
                ...(selection.skipped.length ? { skipped: selection.skipped } : {}),
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
