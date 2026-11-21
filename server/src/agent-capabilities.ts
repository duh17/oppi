/**
 * The one owner of "what may this Agent do in this session", for both engines.
 *
 * Classic (`sdk-backend.ts`) and durable (`durable-agent.ts`, `durable-backend.ts`,
 * `durable-mcp.ts`) both call `compileAgentCapabilities` and use its answer as-is: the tool
 * policy, the MCP servers, the plugin selection, the Skills filter, and the context toggles.
 * Nothing else reads a definition to decide a session's capabilities.
 *
 * Two rules keep the model honest:
 *
 * - A tier never needs an allow list. `full` is a normal session (only exclusions), and
 *   `readonly` is a normal session that may not write. What a session *has* comes from the
 *   extensions that are selected, not from a second list of names that can drift from them.
 * - Transport is derived, never stored. An Agent names MCP servers and tools; whether that
 *   needs `codemode` or `tool_search` is this file's answer for the resolved exposure, so a
 *   workspace switching a server from `direct` to `codemode` cannot break an Agent.
 */
import {
  isAgentDefinitionV1,
  type AgentCoreTier,
  type AgentDefinition,
  type AgentMcpSelection,
  type AgentMcpServerFact,
} from "./agent-definition.js";
import { AgentConfigurationError } from "./agent-launch-errors.js";

/** The built-in coding tools per tier. `full` adds nothing: the session's own set applies. */
export const AGENT_CORE_TIER_TOOLS: Readonly<Record<AgentCoreTier, readonly string[]>> = {
  full: ["read", "write", "edit", "bash", "ls", "find", "grep"],
  readonly: ["read", "bash", "ls", "find", "grep"],
};

/** The tools a tier may not use, so `readonly` stays "read and shell only" without an allow list. */
const AGENT_TIER_DENIED_TOOLS: Readonly<Record<AgentCoreTier, readonly string[]>> = {
  full: [],
  readonly: ["write", "edit"],
};

/**
 * The built-in plugins whose tools a read-only Agent keeps without naming them: the session's own
 * voice, because a live call is the session's rather than the Agent's reach. Names are the
 * catalog's, since the facts come from the catalog. A toggle's package needs no entry (its switch
 * decides its tool), transport is never a plugin fact, and an MCP extension is matched by its
 * `oppi.mcp/` prefix; every other built-in plugin's tools stay out unless the Agent names it.
 */
const AGENT_SESSION_OWN_PLUGINS: ReadonlySet<string> = new Set(["oppi-live-voice"]);

/** The tool each capability toggle turns on, and the plugin that offers it in a classic session. */
export const AGENT_TOGGLE_TOOLS = {
  ask: { tool: "ask", plugin: "ask" },
  notify: { tool: "notify", plugin: "oppi-notify" },
  subagent: { tool: "subagent", plugin: "subagents" },
} as const;

/** MCP's resource tools: a server's resources are part of reaching that server. */
export const AGENT_MCP_RESOURCE_TOOL_NAMES = [
  "list_mcp_resources",
  "list_mcp_resource_templates",
  "read_mcp_resource",
] as const;

/** The tools no Agent writes by name: the MCP transport meta-tools the compiler derives. */
export const AGENT_DISCOVERY_TOOLS = ["codemode", "tool_search"] as const;
export type AgentDiscoveryTool = (typeof AGENT_DISCOVERY_TOOLS)[number];

/** Pi's MCP namespace for a server name: what its tool names are prefixed with. */
export function agentMcpNamespace(serverName: string): string {
  return `mcp__${serverName.replace(/-/g, "_")}`;
}

/** One built-in plugin as a runtime loads it: its name, and the tools it contributes. */
export interface AgentBuiltinPluginFact {
  readonly name: string;
  readonly tools: readonly string[];
}

/**
 * The tools of Oppi's own built-in plugins a read-only Agent may not use, because it did not name
 * the plugin. A read-only Agent states what it may reach; a feature plugin it never asked for is
 * also a way to write (`sqlite_query`, `godot_export`), so it does not arrive by omission — an
 * Agent that names no plugins reaches none of them. Both engines call this with their own
 * built-in inventory, so the two sessions get the same answer.
 */
export function unchosenBuiltinToolExclusions(
  core: AgentCoreTier,
  plugins: readonly string[] | undefined,
  builtins: readonly AgentBuiltinPluginFact[] | undefined,
): string[] {
  if (core !== "readonly" || builtins === undefined) return [];
  const named = new Set(plugins ?? []);
  const togglePlugins = new Set<string>(
    Object.values(AGENT_TOGGLE_TOOLS).map((toggle) => toggle.plugin as string),
  );
  // A plugin that wraps a coding tool must not take that tool away: the tier decides those.
  const tierTools = new Set(AGENT_CORE_TIER_TOOLS[core]);
  const excluded: string[] = [];
  for (const builtin of builtins) {
    if (named.has(builtin.name)) continue;
    if (togglePlugins.has(builtin.name)) continue;
    if (AGENT_SESSION_OWN_PLUGINS.has(builtin.name)) continue;
    // A session's own MCP extensions are per session, not an Agent's choice.
    if (builtin.name.startsWith("oppi.mcp/")) continue;
    for (const tool of builtin.tools) if (!tierTools.has(tool)) excluded.push(tool);
  }
  return [...new Set(excluded)];
}

/**
 * The built-in plugins and tools Oppi offers, read from its catalog with a short cache. A failed
 * read with nothing cached answers `null` (unknown) rather than `[]` (none): the compiler refuses a
 * read-only Agent on unknown, since "no built-ins" would hand it every one of them.
 */
export function createBuiltinPluginFactsReader(
  read: () => Promise<readonly AgentBuiltinPluginFact[]>,
  options: { now?: () => number; ttlMs?: number; onError?: (error: unknown) => void } = {},
): () => Promise<readonly AgentBuiltinPluginFact[] | null> {
  const now = options.now ?? Date.now;
  const ttlMs = options.ttlMs ?? 60_000;
  let cache: { readonly at: number; readonly facts: readonly AgentBuiltinPluginFact[] } | undefined;
  return async () => {
    if (cache !== undefined && now() - cache.at < ttlMs) return cache.facts;
    try {
      const facts = await read();
      cache = { at: now(), facts };
      return facts;
    } catch (error) {
      options.onError?.(error);
      // An older answer is still true enough to protect a read-only Agent; no answer is unknown.
      return cache?.facts ?? null;
    }
  };
}

/** A compiled Agent: everything a session needs, with no definition left to interpret. */
export interface CompiledAgentCapabilities {
  readonly core: AgentCoreTier;
  /**
   * The Pi tool allow list, or undefined: `full` and `readonly` both compile to exclusions only,
   * so a session's own tools (the Pi Tools setting, its plugins) stay in force.
   */
  readonly allowed?: readonly string[];
  readonly excluded: readonly string[];
  /** `codemode` / `tool_search`: the discovery tools this session may use. */
  readonly discovery: readonly AgentDiscoveryTool[];
  /** `servers` undefined means every configured server; an empty list means none. */
  readonly mcp: {
    readonly enabled: boolean;
    readonly servers?: readonly string[];
    readonly tools?: AgentMcpSelection;
  };
  /**
   * The plugins the Agent itself selected; undefined means every plugin the runtime may load.
   * A name here that cannot load fails the launch: the Agent asked for it.
   */
  readonly plugins?: readonly string[];
  /** Skill names to present; undefined means Pi discovery. */
  readonly skills?: readonly string[];
  readonly contextFiles: boolean;
  readonly sessionHistory: boolean;
  readonly ask: boolean;
  readonly notify: boolean;
  readonly subagent: boolean;
  /** Plain-word reasons this session is narrower than the Agent asked for. */
  readonly warnings: readonly string[];
}

export interface CompileAgentCapabilitiesInput {
  readonly definition: AgentDefinition;
  readonly engine: "classic" | "durable";
  readonly runtime: "host" | "sandbox";
  /** Every MCP server this launch would load, before the Agent's selection narrows them. */
  readonly mcpServers?: readonly AgentMcpServerFact[];
  /** Whether the server's MCP switch is on; off means no server is reachable either way. */
  readonly mcpAvailable?: boolean;
  /**
   * Oppi's own plugins and their tools, read from the server's catalog once and given to both
   * engines: a read-only Agent may not use one it did not name. Undefined means the caller has no
   * catalog (tests, a tool that compiles in isolation), and the rule adds nothing.
   */
  readonly builtinPlugins?: readonly AgentBuiltinPluginFact[];
  /**
   * The catalog could not be read and nothing was cached: what the built-ins offer is unknown.
   * A read-only Agent is refused (`agent_builtin_plugins_unavailable`), because the alternative is
   * handing it tools it did not name; a full Agent's tools do not depend on it and it starts.
   */
  readonly builtinPluginsUnknown?: boolean;
}

/**
 * An Agent's capabilities for one session. Deterministic: the same definition and facts compile
 * to the same plan, which is what the launch tests compare against.
 */
export function compileAgentCapabilities(
  input: CompileAgentCapabilitiesInput,
): CompiledAgentCapabilities {
  // A row the one-time migration could not rewrite still holds v1 wiring. Reading it as "no
  // capabilities stated" would grant a full session with every plugin and every MCP server, so
  // every path that compiles a definition refuses it here: the launch route, schedules, durable
  // subagent spawn, and resume alike.
  if (isAgentDefinitionV1(input.definition)) {
    throw new AgentConfigurationError(
      "agent_definition_v2_required",
      {},
      `Agent ${input.definition.name} is still stored in the old format`,
    );
  }
  const capabilities = input.definition.capabilities ?? {};
  const core: AgentCoreTier = capabilities.core ?? "full";
  // Fail closed. A read-only Agent's tool set is "what it named, and nothing else", which needs
  // Oppi's plugin inventory; an unknown inventory would silently widen it.
  if (input.builtinPluginsUnknown === true && core === "readonly") {
    throw new AgentConfigurationError(
      "agent_builtin_plugins_unavailable",
      {},
      `Agent ${input.definition.name} runs read-only, and Oppi could not read its plugin ` +
        `inventory to keep unnamed tools out of the session. Try launching again, or run it with ` +
        `full access.`,
    );
  }
  const ask = capabilities.ask ?? true;
  const notify = capabilities.notify ?? true;
  const subagent = capabilities.subagent ?? true;
  const plugins = input.definition.capabilities?.plugins;

  const mcp = compileMcp({
    selection: capabilities.mcp,
    servers: input.mcpServers ?? [],
    available: input.mcpAvailable !== false,
    engine: input.engine,
    runtime: input.runtime,
  });

  // Pi registers `tool_search` inactive and declares a deferred tool to nobody until it loads.
  // A full Agent may reach every loaded plugin, so the search is part of a normal session here,
  // whatever the Pi Tools setting says: a plugin's deferred tools (imagen's image tools, secret's)
  // are otherwise unreachable. A read-only Agent does not get it: Oppi's catalog reports tool
  // names, not exposures, so nothing can say whether a plugin it named defers a tool, and the
  // search would let it load tools it never named. MCP servers ask for it through their own
  // exposure, which `compileMcp` reports.
  const discovery: AgentDiscoveryTool[] = [
    ...mcp.discovery,
    ...(core === "full" && !mcp.discovery.includes("tool_search")
      ? (["tool_search"] as const)
      : []),
  ];

  const deniedDiscovery = mcp.selection.enabled
    ? []
    : AGENT_DISCOVERY_TOOLS.filter((tool) => !discovery.includes(tool));
  const excluded = [
    ...AGENT_TIER_DENIED_TOOLS[core],
    ...(ask ? [] : [AGENT_TOGGLE_TOOLS.ask.tool]),
    ...(notify ? [] : [AGENT_TOGGLE_TOOLS.notify.tool]),
    ...(subagent ? [] : [AGENT_TOGGLE_TOOLS.subagent.tool]),
    // A read-only Agent keeps codemode and tool search only when an admitted server needs them:
    // both reach whatever the servers expose, which a read-only Agent asked to narrow.
    ...(core === "readonly" ? deniedDiscovery : []),
    ...mcp.excludedTools,
    // A feature plugin it never named is also a way to write (`sqlite_query`, `godot_export`).
    ...unchosenBuiltinToolExclusions(core, plugins, input.builtinPlugins),
  ];

  return {
    core,
    excluded: [...new Set(excluded)],
    discovery,
    mcp: mcp.selection,
    ...(plugins === undefined ? {} : { plugins: [...new Set(plugins)] }),
    ...(input.definition.context?.skills === undefined
      ? {}
      : { skills: [...new Set(input.definition.context.skills)] }),
    contextFiles: input.definition.context?.contextFiles !== false,
    sessionHistory: input.definition.context?.sessionHistory !== false,
    ask,
    notify,
    subagent,
    warnings: mcp.warnings,
  };
}

/**
 * The Skills to present: undefined keeps Pi discovery, otherwise only the named ones, matched by
 * a Skill's folder (the name every Agent means). Returns the names no discovered Skill answers,
 * so the launch can say exactly what is missing.
 */
export function selectAgentSkills<T extends { readonly filePath: string }>(
  skills: readonly T[],
  names: readonly string[] | undefined,
): { skills: T[]; missing: string[] } {
  if (names === undefined) return { skills: [...skills], missing: [] };
  const byName = new Map<string, T>();
  for (const skill of skills) {
    const name = skillFolderName(skill.filePath);
    if (!byName.has(name)) byName.set(name, skill);
  }
  const kept: T[] = [];
  const missing: string[] = [];
  for (const name of new Set(names)) {
    const found = byName.get(name);
    if (found) kept.push(found);
    else missing.push(name);
  }
  return { skills: kept, missing };
}

/** A Skill's name: the folder holding its `SKILL.md`. */
export function skillFolderName(filePath: string): string {
  const segments = filePath.split(/[/\\]/).filter(Boolean);
  return segments.length >= 2 ? (segments[segments.length - 2] ?? "") : "";
}

/** The one warning text for a plugin an Agent names that this engine has no version of. */
/**
 * The plugins an Agent names that a durable session cannot load. Oppi's built-in owner packages
 * (`background-jobs`) do not appear in the harness's `loadedPackages`, so the caller passes their
 * names too: without them every Agent that names one claims a plugin with no version. A classic-only
 * plugin such as `secret` is not among them, so naming it is reported, as it should be.
 */
export function missingDurablePlugins(
  named: readonly string[] | undefined,
  loaded: readonly string[],
): string[] | undefined {
  if (named === undefined) return undefined;
  const available = new Set(loaded);
  const missing = named.filter((name) => !available.has(name));
  return missing.length > 0 ? missing : undefined;
}

export function skippedPluginsWarning(names: readonly string[] | undefined): string | undefined {
  if (!names?.length) return undefined;
  const noun = names.length === 1 ? "plugin" : "plugins";
  return `This Agent names ${noun} with no durable version: ${names.join(", ")}. It started without ${names.length === 1 ? "it" : "them"}.`;
}

/** The one warning text for a Skill name nothing presents. */
export function missingAgentSkillsWarning(missing: readonly string[]): string | undefined {
  if (!missing.length) return undefined;
  const noun = missing.length === 1 ? "Skill" : "Skills";
  return `This Agent names ${noun} this session cannot read: ${missing.join(", ")}. It started without ${missing.length === 1 ? "it" : "them"}.`;
}

interface CompiledMcp {
  readonly selection: CompiledAgentCapabilities["mcp"];
  /** Tool names and patterns this session may not use, so an exclusion-only policy still narrows. */
  readonly excludedTools: string[];
  readonly discovery: AgentDiscoveryTool[];
  readonly warnings: string[];
}

/**
 * MCP: which servers an Agent reaches, and the transport tools that make them reachable.
 *
 * `servers` names match by namespace, so `chrome-devtools` and `chrome_devtools` are one server.
 * A server the Agent does not admit is excluded by pattern, and the durable engine also drops it
 * before connecting, so a blocked server never prints a namespace into the codemode section.
 */
function compileMcp(input: {
  selection: AgentMcpSelection | undefined;
  servers: readonly AgentMcpServerFact[];
  available: boolean;
  engine: "classic" | "durable";
  runtime: "host" | "sandbox";
}): CompiledMcp {
  if (!input.available) {
    // The server's MCP switch is off: no session reaches a server, whatever it selects.
    return {
      selection: { enabled: false, servers: [] },
      excludedTools: ["mcp__*", ...AGENT_MCP_RESOURCE_TOOL_NAMES],
      discovery: [],
      warnings: [],
    };
  }
  const configured = input.servers.filter((server) => server.enabled);
  const names = input.selection === undefined ? undefined : Object.keys(input.selection);
  if (names !== undefined && names.length === 0) {
    return {
      selection: { enabled: false, servers: [] },
      excludedTools: ["mcp__*", ...AGENT_MCP_RESOURCE_TOOL_NAMES],
      discovery: [],
      warnings: [],
    };
  }
  const admitted =
    names === undefined
      ? configured
      : configured.filter((server) =>
          names.some((name) => agentMcpNamespace(name) === agentMcpNamespace(server.name)),
        );
  const admittedNamespaces = new Set(admitted.map((server) => agentMcpNamespace(server.name)));
  // A server this launch configures but the Agent does not admit: its tools are never available.
  const excludedTools = configured
    .filter((server) => !admittedNamespaces.has(agentMcpNamespace(server.name)))
    .map((server) => `${agentMcpNamespace(server.name)}__*`);

  const exposures = new Set(admitted.flatMap((server) => server.exposures));
  const codemodeReachable =
    exposures.has("codemode") && !(input.engine === "classic" && input.runtime === "sandbox");
  const toolSearchReachable = exposures.has("deferred") || exposures.has("codemode");
  const discovery: AgentDiscoveryTool[] = [
    ...(codemodeReachable ? (["codemode"] as const) : []),
    ...(toolSearchReachable ? (["tool_search"] as const) : []),
  ];

  const warnings: string[] = [];
  // A per-server tool list is enforced by exclusion where the server's tools are known, so an
  // exclusion-only policy still narrows: exclusions can deny a tool, and nothing can allow one.
  for (const server of admitted) {
    const selection = input.selection?.[matchingKey(input.selection, server.name) ?? ""];
    if (selection === undefined || selection === "all") continue;
    const kept = new Set(selection);
    if (server.tools.length === 0 && input.engine === "classic") {
      // Classic has already started Pi's MCP extension with the whole server; only exclusions can
      // narrow it, and they need the tool names.
      warnings.push(
        `MCP server "${server.name}" has no known tool list yet, so this session may reach more of its tools than the ${kept.size} this Agent names.`,
      );
      continue;
    }
    for (const tool of server.tools) {
      if (!kept.has(tool)) excludedTools.push(`${agentMcpNamespace(server.name)}__${tool}`);
    }
  }

  return {
    selection: {
      enabled: true,
      ...(names === undefined ? {} : { servers: admitted.map((server) => server.name) }),
      ...(names === undefined ? {} : { tools: input.selection }),
    },
    excludedTools,
    discovery,
    warnings,
  };
}

function matchingKey(
  selection: AgentMcpSelection | undefined,
  serverName: string,
): string | undefined {
  if (!selection) return undefined;
  const namespace = agentMcpNamespace(serverName);
  return Object.keys(selection).find((key) => agentMcpNamespace(key) === namespace);
}
