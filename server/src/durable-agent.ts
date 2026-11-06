import {
  defineDoc,
  type AgentChange,
  type Extension,
  type ModelRef,
  type ToolRegistration,
} from "@earendil-works/pi-durable";

import type { AgentDefinition } from "./agent-launch-service.js";
import type { LoadedPlugin } from "./plugin-host.js";
import { DURABLE_MCP_EXTENSION_PREFIX } from "./durable-mcp.js";
import { BUILTIN_EXTENSION_PATH_PREFIX } from "./host-mcp-extensions.js";
import type { ThinkingLevel } from "./thinking-levels.js";
import type { Session } from "./types.js";
import { LIVE_VOICE_EXTENSION } from "../plugins/live-voice/contract.js";

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
   * An exact Extension selection: owner plugins' extensions by name, MCP and codemode or not,
   * and the names of selected Extensions the session runs without (no durable version), for its
   * warning.
   */
  extensions?: { packages: string[]; mcp: boolean; codemode: boolean; skipped?: string[] };
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
  // Written at launch and on an Agent change.
  checkpointWhen: () => false,
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

/**
 * The `instructions` of a durable session: Oppi's default or the Agent's replacement, then cwd and
 * the Agent's append. The workspace prompt is one of Oppi's appends, rendered by the
 * `project-context` plugin's `oppi_append` section from the current workspace.
 */
function durableInstructions(options: {
  cwd: string;
  instructions?: AgentDefinition["instructions"];
}): string {
  const { cwd, instructions } = options;
  return [
    instructions?.mode === "replace" ? instructions.text : DURABLE_DEFAULT_INSTRUCTIONS,
    `Working directory: ${cwd}`,
    instructions?.mode === "append" ? instructions.text : undefined,
  ]
    .filter(Boolean)
    .join("\n\n");
}

/**
 * Pi's built-in tool names (`allToolNames`, `pi-coding-agent` dist/core/tools/index.js). Durable
 * offers them through CodingTools (read, bash, edit, write) and the file tools (ls, find, grep).
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
 * The tools Pi's `defaultTools` setting (the Pi Tools page) turns on and off: Pi's built-in tools
 * and the tools of its built-in `codemode` and `tool-search` extensions. Every other tool, an
 * extension's or an MCP server's, is on unless a tool policy says otherwise.
 */
const PI_TOOLS_SETTING_NAMES: ReadonlySet<string> = new Set([
  ...PI_BUILTIN_TOOL_NAMES,
  "codemode",
  "tool_search",
]);

/** Pi's `DEFAULT_TOOL_NAMES` (`pi-coding-agent` dist/core/settings-manager.js), not exported. */
const PI_DEFAULT_TOOL_NAMES = ["read", "bash", "edit", "write"];

/**
 * The tools Pi's `defaultTools` enables for a session whose settings are `settings`, as
 * `createAgentSession` reads it: plain names replace Pi's defaults, `+name` and `-name` edit them.
 */
export function piDefaultTools(settings: {
  getDefaultTools(): string[] | undefined;
}): ReadonlySet<string> {
  return new Set(settings.getDefaultTools() ?? PI_DEFAULT_TOOL_NAMES);
}

/**
 * Pi's tool policy (`createAgentSession` in `pi-coding-agent` dist/core/sdk.js): an allow list is
 * the enabled set and overrides `noTools` and `defaultTools`; otherwise `noTools: "all"` enables
 * nothing, `"builtin"` drops only Pi's built-in tools, keeping extension and MCP tools, and a tool
 * the Pi Tools setting governs is on only when `piTools` (`piDefaultTools`) names it. `excluded`
 * always applies.
 */
export function toolAllowed(
  policy: DurableToolPolicy | undefined,
  name: string,
  piTools: ReadonlySet<string>,
): boolean {
  if (policy?.excluded?.includes(name)) return false;
  if (policy?.allowed) return policy.allowed.includes(name);
  if (policy?.noTools === "all") return false;
  if (policy?.noTools === "builtin" && PI_BUILTIN_TOOL_NAMES.has(name)) return false;
  return !PI_TOOLS_SETTING_NAMES.has(name) || piTools.has(name);
}

/** What Oppi knows of the classic Extensions a saved Agent selects by ID. */
export interface ClassicExtensionIndex {
  /** IDs of classic Extensions whose durable version Oppi bundles, so every session has it. */
  readonly bundled: ReadonlySet<string>;
  /** A readable name per ID, for the warning about Extensions a session runs without. */
  readonly names: ReadonlyMap<string, string>;
}

const MCP_EXTENSION_ID = `${BUILTIN_EXTENSION_PATH_PREFIX}mcp`;
const CODEMODE_EXTENSION_ID = `${BUILTIN_EXTENSION_PATH_PREFIX}codemode`;
const TOOL_SEARCH_EXTENSION_ID = `${BUILTIN_EXTENSION_PATH_PREFIX}tool-search`;

/**
 * Whether a session of `runtime` may select the owner plugin `loaded`: it declares the runtime
 * (`runtimes`), or the session is a sandbox one that opted into it (`optedIn`, Extension IDs of
 * a saved Agent's selection or the workspace's `sandboxConfig.hostExtensions`). A plugin that
 * does not declare `sandbox` acts on the host, past the VM, so a sandbox gets it only by opt-in.
 */
export function pluginAllowedIn(
  loaded: LoadedPlugin,
  runtime: "host" | "sandbox",
  optedIn: readonly string[],
): boolean {
  if (loaded.runtimes.includes(runtime)) return true;
  return runtime === "sandbox" && loaded.extensionIds.some((id) => optedIn.includes(id));
}

/**
 * The durable extensions a saved Agent's exact Extension selection names. `builtin:mcp` is the
 * session's own MCP extension, which brings durable's `tool_search` (it searches MCP tools, so
 * `builtin:tool-search` needs `builtin:mcp`), and `builtin:codemode` is pi-durable's codemode, as
 * in classic. An ID whose durable version Oppi bundles is in every session already. Any other ID
 * must belong to a Pi package whose plugin is loaded, enabled, and allowed in this runtime (the
 * selection is a sandbox's opt-in, `pluginAllowedIn`). The rest are `skipped` by name: the
 * session starts without them and warns.
 */
export function resolveDurableExtensionSelection(
  extensionIds: readonly string[],
  loaded: readonly LoadedPlugin[],
  classic: ClassicExtensionIndex,
  runtime: "host" | "sandbox",
  enabled: (name: string) => boolean,
): { packages: LoadedPlugin[]; mcp: boolean; codemode: boolean; skipped: string[] } {
  const ids = new Set(extensionIds);
  const mcp = ids.has(MCP_EXTENSION_ID);
  const codemode = ids.has(CODEMODE_EXTENSION_ID);
  const packages: LoadedPlugin[] = [];
  // By name: two IDs of one package are one skipped Extension.
  const skipped = new Set<string>();
  for (const id of ids) {
    if (
      id === MCP_EXTENSION_ID ||
      id === CODEMODE_EXTENSION_ID ||
      (id === TOOL_SEARCH_EXTENSION_ID && mcp)
    )
      continue;
    if (classic.bundled.has(id)) continue;
    const found = loaded.find((candidate) => candidate.extensionIds.includes(id));
    if (found && pluginAllowedIn(found, runtime, [id]) && enabled(found.extension.name)) {
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
  return { packages, mcp, codemode, skipped: [...skipped] };
}

/**
 * How `subagent spawn` narrows the tools a child gets: an intersection only, never a widening.
 * `parentTools` is what the spawning session's own agent offers.
 */
export type DurableToolNarrowing = {
  readonly parentTools: readonly string[];
  /** Only these tools. */
  readonly tools?: readonly string[];
  /** Never these tools. */
  readonly excludeTools?: readonly string[];
  /** Read and run commands only. */
  readonly readOnly?: boolean;
};

/** What `readOnly: true` leaves: Pi's `read` and `bash` (`bash` is not a sandbox). */
const READ_ONLY_TOOL_NAMES: ReadonlySet<string> = new Set(["read", "bash"]);

/**
 * The child's tools: those the parent offers and the child's own policy allows, then the spawn's
 * ask. `tools` and `readOnly` name an exact set (together, only their intersection), so the
 * document's policy becomes that allow list. `excludeTools` alone only adds exclusions: the
 * policy keeps its shape, so a tool the child gets later, such as an MCP or `notify` tool that
 * only exists at attach, is not dropped for being outside a list nobody asked for. Either way
 * every tool of the child's extensions absent from the parent is excluded by name, so the stored
 * policy also caps what an attach would add: a saved Agent's package tools, and Pi tools the Pi
 * Tools setting enables (`selectable`, before the setting filters them out of `tools`).
 */
function narrowTools(
  tools: readonly ToolRegistration[],
  selectable: readonly ToolRegistration[],
  policy: DurableToolPolicy | undefined,
  narrowing: DurableToolNarrowing,
  piTools: ReadonlySet<string>,
): { tools: ToolRegistration[]; policy: DurableToolPolicy } {
  const offered = new Set(narrowing.parentTools);
  const named = narrowing.tools === undefined ? undefined : new Set(narrowing.tools);
  const wanted = narrowing.readOnly
    ? named
      ? new Set([...READ_ONLY_TOOL_NAMES].filter((name) => named.has(name)))
      : READ_ONLY_TOOL_NAMES
    : named;
  // A package extension the child starts with may offer tools the parent never had: the cap is
  // the parent's set, so store them as exclusions too and a later attach cannot bring them back.
  const unoffered = selectable.filter((tool) => !offered.has(tool.name)).map((tool) => tool.name);
  const excluded = [
    ...new Set([...(policy?.excluded ?? []), ...(narrowing.excludeTools ?? []), ...unoffered]),
  ];
  const kept = tools.filter(
    (tool) =>
      offered.has(tool.name) &&
      toolAllowed(policy, tool.name, piTools) &&
      (wanted === undefined || wanted.has(tool.name)) &&
      !excluded.includes(tool.name),
  );
  return {
    tools: kept,
    policy: wanted
      ? { allowed: kept.map((tool) => tool.name) }
      : { ...policy, ...(excluded.length ? { excluded } : {}) },
  };
}

/**
 * `instructions` with its `Working directory` line pointing at `cwd`. A child inherits its
 * parent's instructions; a worktree child says where it really runs.
 */
export function retargetInstructions(
  instructions: string | undefined,
  cwd: string,
): string | undefined {
  if (instructions === undefined) return undefined;
  const line = /^Working directory: .*$/m;
  if (line.test(instructions)) return instructions.replace(line, `Working directory: ${cwd}`);
  return `${instructions}\n\nWorking directory: ${cwd}`;
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
  /** A `subagent spawn`'s narrow-only asks; their result is never wider than the parent's tools. */
  narrow?: DurableToolNarrowing;
  runtime: "host" | "sandbox";
  /**
   * The extensions to start from: the parent's for a child, Oppi's defaults (built-ins and every
   * owner plugin's extension of the runtime) for a top-level session. MCP extensions are
   * per session and are dropped; the session attaches its own.
   */
  base: readonly Extension[];
  /** Every loaded owner plugin. */
  loaded: readonly LoadedPlugin[];
  /** A sandbox workspace's `sandboxConfig.hostExtensions`: host-only plugins it opted into. */
  hostExtensionIds?: readonly string[];
  classic: ClassicExtensionIndex;
  /** Whether the server enables the durable extension of this name (`isExtensionEnabled`). */
  enabled: (name: string) => boolean;
  /**
   * The tools of the Pi Tools setting this session gets (`piDefaultTools`): the setting for a
   * top-level session, the parent's tools for a child.
   */
  piTools: ReadonlySet<string>;
  /** pi-durable's `codemode`; an exact Extension selection keeps it only with `builtin:codemode`. */
  codemode: Extension;
  /** Oppi's extension that offers `subagent`. */
  sessions: Extension;
  spawn: boolean;
  /** Oppi's extension that offers `notify`, and whether this conversation selects it. */
  notify: Extension;
  notifies: boolean;
  grant: boolean;
  /** Where the instructions come from; unset keeps the base agent's (a child without an Agent). */
  instructions?: { cwd: string };
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
      // A call belongs to the session it attached to; a child spawned during one has no voice.
      extension.name !== LIVE_VOICE_EXTENSION &&
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
  // An exact selection without `builtin:codemode` has no codemode, as a classic one loads none.
  const base =
    selection && !selection.codemode
      ? kept.filter((extension) => extension.name !== input.codemode.name)
      : kept;
  const packages = !saved
    ? []
    : (
        selection?.packages ??
        loaded.filter((entry) => pluginAllowedIn(entry, runtime, input.hostExtensionIds ?? []))
      ).map((entry) => entry.extension);
  // A disabled extension leaves every selection, a child's copy of its parent's included.
  const extensions = [
    ...base,
    ...(input.spawn ? [input.sessions] : []),
    ...(input.notifies ? [input.notify] : []),
    ...packages,
  ].filter((extension) => input.enabled(extension.name));

  const policy: DurableToolPolicy | undefined =
    input.policy ??
    (saved ? savedPolicy(definition?.sessionDefaults) : undefined) ??
    input.inherited?.tools;
  const resolved: ToolRegistration[] = extensions
    .flatMap((extension) => extension.tools ?? [])
    .filter((tool) => toolAllowed(policy, tool.name, input.piTools));
  const narrowed = input.narrow
    ? narrowTools(
        resolved,
        extensions.flatMap((extension) => extension.tools ?? []),
        policy,
        input.narrow,
        input.piTools,
      )
    : undefined;
  const tools: ToolRegistration[] = narrowed?.tools ?? resolved;
  const toolPolicy: DurableToolPolicy | undefined = narrowed?.policy ?? policy;

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
                codemode: selection.codemode,
                ...(selection.skipped.length ? { skipped: selection.skipped } : {}),
              },
            }
          : {}),
        ...(toolPolicy ? { tools: toolPolicy } : {}),
      }
    : {
        // A copy of the parent, with its own delegation.
        ...structuredClone(input.inherited ?? {}),
        spawn: input.spawn,
        grant: input.grant,
        ...(toolPolicy ? { tools: toolPolicy } : {}),
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
