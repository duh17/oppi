import {
  defineDoc,
  type AgentChange,
  type Extension,
  type ModelRef,
  type ToolRegistration,
} from "@earendil-works/pi-durable";

import type { AgentDefinition } from "./agent-definition.js";
import type { CompiledAgentCapabilities } from "./agent-capabilities.js";
import type { LoadedPlugin } from "./plugin-host.js";
import { DURABLE_MCP_EXTENSION_PREFIX } from "./durable-mcp.js";
import { PI_BUILTIN_TOOL_NAMES, PI_DEFAULT_TOOL_NAMES } from "./pi-global-config.js";
import type { ThinkingLevel } from "./thinking-levels.js";
import type { Session } from "./types.js";
import { LIVE_VOICE_EXTENSION } from "../plugins/live-voice/contract.js";

type DurableToolPolicy = NonNullable<NonNullable<Session["launch"]>["tools"]>;

/** The Skills and context an Agent selected, as its conversation stores them. */
export type DurableAgentResources = {
  /** Skill names, the folder of each `SKILL.md`; unset means Pi discovery. */
  skills?: string[];
  /** False turns AGENTS.md and the workspace prompt off. */
  contextFiles?: boolean;
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
  /**
   * True when the Agent's instructions replace the base prompt, so Oppi's appends stand in for
   * Pi's discovered `APPEND_SYSTEM.md`. AGENTS.md is `resources.contextFiles`, never this.
   */
  replacePrompt?: true;
  /** False when the Agent turns off `history://` and `agent://` reads (`resources.noSessionHistory`). */
  sessionHistory?: false;
  /**
   * The plugins this Agent selected by name, whether it reaches MCP at all, and whether it is
   * offered codemode (a read-only Agent gets it only through an admitted server).
   */
  extensions?: { packages: string[]; mcp: boolean; codemode: boolean };
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
 * The tools Pi's `defaultTools` setting (the Pi Tools page) turns on and off: Pi's built-in tools
 * and the tools of its built-in `codemode` and `tool-search` extensions. Every other tool, an
 * extension's or an MCP server's, is on unless a tool policy says otherwise.
 */
const PI_TOOLS_SETTING_NAMES: ReadonlySet<string> = new Set([
  ...PI_BUILTIN_TOOL_NAMES,
  "codemode",
  "tool_search",
]);

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

/**
 * Whether a session of `runtime` may select the owner plugin `loaded`: it declares the runtime
 * (`runtimes`), or the session is a sandbox one that opted into it — by plugin name (an Agent's
 * own `plugins` selection) or by the classic extension ID a workspace lists in
 * `sandboxConfig.hostExtensions`. A plugin that does not declare `sandbox` acts on the host, past
 * the VM, so a sandbox gets it only by opt-in.
 */
export function pluginAllowedIn(
  loaded: LoadedPlugin,
  runtime: "host" | "sandbox",
  optedIn: readonly string[],
): boolean {
  if (loaded.runtimes.includes(runtime)) return true;
  return (
    runtime === "sandbox" &&
    (optedIn.includes(loaded.name) || loaded.extensionIds.some((id) => optedIn.includes(id)))
  );
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
  /**
   * Whether the saved Agent's own plugin selection also opts a sandbox into the host-only plugins
   * it names: an owner's launch does. A sandbox parent's `subagent spawn` does not, because the
   * sandbox's model picked the Agent; only `hostExtensionIds` admit them for its child.
   */
  agentOptsIn?: boolean;
  /** What the Agent may do here, from `compileAgentCapabilities`. */
  compiled?: CompiledAgentCapabilities;
  /** Whether the server enables the durable extension of this name (`isExtensionEnabled`). */
  enabled: (name: string) => boolean;
  /**
   * The tools of the Pi Tools setting this session gets (`piDefaultTools`): the setting for a
   * top-level session, the parent's tools for a child.
   */
  piTools: ReadonlySet<string>;
  /** pi-durable's `codemode`; a read-only Agent gets it only through an admitted MCP server. */
  codemode: Extension;
  /** Oppi's extension that offers `subagent`. */
  sessions: Extension;
  spawn: boolean;
  /**
   * Oppi's extension that offers `notify` (none while its plugin fails to load), and whether this
   * conversation selects it. A disabled one leaves with the other disabled extensions.
   */
  notify: Extension | undefined;
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
 * The Agent itself is already compiled (`compileAgentCapabilities`): this function selects the
 * extensions the plan names, applies its tool policy, and records what the conversation runs as.
 */
export function resolveDurableAgent(input: DurableAgentInput): {
  change: DurableAgentChange;
  doc: OppiAgentState;
} {
  const { saved, runtime, loaded, compiled } = input;
  const definition = saved?.definition;
  const pluginNames = new Set(loaded.filter((entry) => entry.extension).map((entry) => entry.name));
  const kept = input.base.filter(
    (extension) =>
      !extension.name.startsWith(DURABLE_MCP_EXTENSION_PREFIX) &&
      extension.name !== input.sessions.name &&
      extension.name !== input.notify?.name &&
      // A call belongs to the session it attached to; a child spawned during one has no voice.
      extension.name !== LIVE_VOICE_EXTENSION &&
      // A saved Agent picks its own plugins; a copy keeps the parent's.
      !(saved && pluginNames.has(extension.name)),
  );
  // A read-only Agent keeps codemode only when an admitted MCP server is reached through it.
  const base =
    compiled?.core === "readonly" && !compiled.discovery.includes("codemode")
      ? kept.filter((extension) => extension.name !== input.codemode.name)
      : kept;
  const optedIn = [
    ...(input.hostExtensionIds ?? []),
    ...(input.agentOptsIn && compiled?.plugins ? compiled.plugins : []),
  ];
  const packages = !saved
    ? []
    : (compiled?.plugins === undefined
        ? loaded.filter((entry) => pluginAllowedIn(entry, runtime, optedIn))
        : loaded.filter(
            (entry) =>
              compiled.plugins?.includes(entry.name) === true &&
              pluginAllowedIn(entry, runtime, optedIn),
          )
      ).map((entry) => entry.extension);
  // A disabled extension leaves every selection, a child's copy of its parent's included.
  const extensions = [
    ...base,
    ...(input.spawn ? [input.sessions] : []),
    ...(input.notifies && input.notify ? [input.notify] : []),
    ...packages,
  ].filter((extension) => input.enabled(extension.name));

  const policy: DurableToolPolicy | undefined =
    input.policy ??
    (compiled && saved ? compiledPolicy(compiled) : undefined) ??
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
        ...(compiled && (compiled.skills !== undefined || !compiled.contextFiles)
          ? {
              resources: {
                ...(compiled.skills !== undefined ? { skills: [...compiled.skills] } : {}),
                ...(compiled.contextFiles ? {} : { contextFiles: false }),
              },
            }
          : {}),
        ...(saved.definition.instructions?.mode === "replace"
          ? { replacePrompt: true as const }
          : {}),
        // Sticky: a sealed parent's child stays sealed whatever Agent it launches as.
        ...(compiled?.sessionHistory === false || input.inherited?.sessionHistory === false
          ? { sessionHistory: false as const }
          : {}),
        ...(compiled?.plugins === undefined
          ? {}
          : {
              extensions: {
                // The packages this session actually selected: a host-only plugin a sandbox did
                // not opt into must not reach the document, or the next attach would load it.
                packages: packages.map((extension) => extension.name),
                mcp: compiled.mcp.enabled,
                codemode: compiled.core === "full" || compiled.discovery.includes("codemode"),
              },
            }),
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

/** The tool policy a compiled plan asks for: exclusions only, so the Pi Tools setting stays in force. */
function compiledPolicy(compiled: CompiledAgentCapabilities): DurableToolPolicy | undefined {
  return compiled.excluded.length ? { excluded: [...compiled.excluded] } : undefined;
}
