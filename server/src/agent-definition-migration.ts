/**
 * The one-time v1 → v2 Agent migration.
 *
 * Before v2 a saved Agent stored Pi wiring: `resources.extensionIds` (SHA256 hashes of extension
 * files), `resources.skillPaths` (absolute host paths), and `sessionDefaults.tools` /
 * `excludeTools` / `noTools` (Pi tool names, including the `codemode` / `tool_search` transport
 * tools). v2 stores what the Agent wants. This module is the only reader of the old shape; it runs
 * once at startup over the rows and version history stored at that moment, and `validateAgentDefinition`
 * refuses anything still in the old shape.
 *
 * The rules preserve what each Agent could actually do, not what its lists happened to say:
 *
 * - An allow list decides the tier (write/edit ⇒ full, else readonly) and, because v2 lets an
 *   Agent state a plugin instead of its tools, the plugins whose tools it names: a plugin that is
 *   not named is not selected.
 * - An exclusion decides the toggles (`ask`, `notify`, `subagent`) and, because v2 lets an Agent
 *   state which MCP servers it reaches, the servers left after the excluded ones. A plugin whose
 *   tools the old policy excluded is not selected.
 * - A version history entry is migrated too: a resumed session reads the version it pinned.
 */
import {
  isAgentDefinitionV1,
  type AgentCapabilities,
  type AgentContext,
  type AgentDefinition,
  type AgentMcpSelection,
  type AgentMcpTools,
} from "./agent-definition.js";
import {
  AGENT_CORE_TIER_TOOLS,
  AGENT_TOGGLE_TOOLS,
  agentMcpNamespace,
} from "./agent-capabilities.js";
import { isRecord } from "./json-shape.js";
import type { ThinkingLevel } from "./thinking-levels.js";

/** What the migration needs to know about this server, built once per run. */
export interface AgentMigrationCatalogs {
  /** Classic extension resource ID → the package it belongs to, whether it is on, and its tools. */
  readonly extensions: ReadonlyMap<
    string,
    { readonly name: string; readonly enabled: boolean; readonly tools: readonly string[] }
  >;
  /** A tool name → the plugin that offers it, for the tool providers on this server. */
  readonly pluginByTool: ReadonlyMap<string, string>;
  /** Every plugin name this server offers, in a stable order, with the tools it offers. */
  readonly plugins: ReadonlyMap<string, readonly string[]>;
  /** MCP server names of the user scope (Pi's `~/.pi/agent/mcp.json`). */
  readonly userMcpServers: readonly string[];
  /** MCP server names each workspace configures in its own `.pi/mcp.json`. */
  readonly workspaceMcpServers: ReadonlyMap<string, readonly string[]>;
  /** The last-known tool names per MCP server, from Oppi's tool cache. */
  readonly mcpServerTools: ReadonlyMap<string, readonly string[]>;
}

export interface AgentMigrationResult {
  /** The v2 definition, or undefined when the stored row is not a v1 definition. */
  readonly definition?: AgentDefinition;
  /** Plain-word notes: what was dropped, and why. Logged once per row. */
  readonly notes: readonly string[];
}

/** The v1 `AgentDefinition` keys this module reads; anything else is carried through as-is. */
interface V1Definition {
  readonly name: string;
  readonly icon?: unknown;
  readonly description?: string;
  readonly instructions?: { readonly mode?: "append" | "replace"; readonly text: string };
  readonly resources?: {
    readonly agentsFiles?: unknown;
    readonly noContextFiles?: boolean;
    readonly skillPaths?: readonly string[];
    readonly extensionIds?: readonly string[];
    readonly noSessionHistory?: boolean;
  };
  readonly sessionDefaults?: {
    readonly model?: string;
    readonly thinkingLevel?: ThinkingLevel;
    readonly tools?: readonly string[];
    readonly excludeTools?: readonly string[];
    readonly noTools?: "all" | "builtin";
  };
  readonly launchConstraints?: unknown;
}

/**
 * Rewrite one stored definition. A definition already in the v2 shape comes back unchanged (with
 * no notes), so this is safe to run over every row on every start.
 */
export function migrateAgentDefinitionV1(
  stored: unknown,
  catalogs: AgentMigrationCatalogs,
): AgentMigrationResult {
  if (!isRecord(stored)) return { notes: [] };
  if (!isAgentDefinitionV1(stored)) return { notes: [] };
  const v1 = stored as unknown as V1Definition;
  const notes: string[] = [];
  const defaults = v1.sessionDefaults ?? {};
  const resources = v1.resources ?? {};
  const allowed = defaults.tools;
  const excluded = defaults.excludeTools ?? [];

  const core = tierFor(v1, notes);
  const noTools = defaults.noTools === "all";
  const toggles = {
    ask: !noTools && toggleOn("ask", allowed, excluded),
    notify: !noTools && toggleOn("notify", allowed, excluded),
    subagent: !noTools && toggleOn("subagent", allowed, excluded),
  };
  const plugins = noTools
    ? []
    : pluginsFor(allowed, resources.extensionIds, excluded, catalogs, notes);
  const mcp = noTools ? {} : mcpFor(allowed, excluded, v1.launchConstraints, catalogs, notes);
  const capabilities: AgentCapabilities = {
    ...(core === "full" ? {} : { core }),
    ...(toggles.ask ? {} : { ask: false }),
    ...(toggles.notify ? {} : { notify: false }),
    ...(toggles.subagent ? {} : { subagent: false }),
    ...(plugins === undefined ? {} : { plugins }),
    ...(mcp === undefined ? {} : { mcp }),
  };
  const context = contextFor(resources);

  const definition: AgentDefinition = {
    name: v1.name,
    ...(v1.icon !== undefined ? { icon: v1.icon as AgentDefinition["icon"] } : {}),
    ...(v1.description !== undefined ? { description: v1.description } : {}),
    ...(v1.instructions?.text !== undefined
      ? {
          instructions: {
            mode: v1.instructions.mode === "replace" ? "replace" : "append",
            text: v1.instructions.text,
          },
        }
      : {}),
    ...(defaults.model !== undefined || defaults.thinkingLevel !== undefined
      ? {
          sessionDefaults: {
            ...(defaults.model !== undefined ? { model: defaults.model } : {}),
            ...(defaults.thinkingLevel !== undefined
              ? { thinkingLevel: defaults.thinkingLevel }
              : {}),
          },
        }
      : {}),
    capabilities,
    ...(context === undefined ? {} : { context }),
    ...(v1.launchConstraints !== undefined
      ? { launchConstraints: v1.launchConstraints as AgentDefinition["launchConstraints"] }
      : {}),
  };
  return { definition, notes };
}

/**
 * The tier: an allow list that names `write`/`edit` is a working Agent, anything narrower is
 * read-only. No policy, or exclusions only, was a normal session.
 */
function tierFor(v1: V1Definition, notes: string[]): "full" | "readonly" {
  const defaults = v1.sessionDefaults ?? {};
  if (v1.resources?.agentsFiles !== undefined) {
    notes.push("dropped resources.agentsFiles (no Agent used it)");
  }
  if (defaults.noTools === "all") {
    notes.push('sessionDefaults.noTools "all" became core: readonly with no plugins');
    return "readonly";
  }
  if (defaults.noTools === "builtin") notes.push('dropped sessionDefaults.noTools "builtin"');
  if (defaults.tools === undefined) return "full";
  const writable = defaults.tools.some(
    (tool) =>
      AGENT_CORE_TIER_TOOLS.full.includes(tool) && !AGENT_CORE_TIER_TOOLS.readonly.includes(tool),
  );
  return writable ? "full" : "readonly";
}

/** A toggle is on unless the policy named its tool and refused it. */
function toggleOn(
  toggle: keyof typeof AGENT_TOGGLE_TOOLS,
  allowed: readonly string[] | undefined,
  excluded: readonly string[],
): boolean {
  const tool = AGENT_TOGGLE_TOOLS[toggle].tool;
  if (excluded.includes(tool)) return false;
  return allowed === undefined || allowed.includes(tool);
}

/**
 * The plugin selection. An allow list selects the plugins whose tools it names; stored extension
 * IDs add the packages the Agent pinned; exclusions remove the plugins whose tools they refuse.
 * Undefined means every plugin, which is what an Agent with neither list had.
 */
function pluginsFor(
  allowed: readonly string[] | undefined,
  extensionIds: readonly string[] | undefined,
  excluded: readonly string[],
  catalogs: AgentMigrationCatalogs,
  notes: string[],
): string[] | undefined {
  const selected = new Set<string>();
  // A list that says anything about plugins is known, even when every entry in it is dropped:
  // an Agent that pinned extensions must never come out of here as "every plugin".
  let known = allowed !== undefined || extensionIds !== undefined;
  if (allowed !== undefined) {
    for (const tool of allowed) {
      const plugin = catalogs.pluginByTool.get(tool);
      if (plugin !== undefined) selected.add(plugin);
    }
  }
  for (const id of extensionIds ?? []) {
    if (id.startsWith("builtin:")) continue;
    const entry = catalogs.extensions.get(id);
    if (!entry) {
      notes.push(`dropped unknown Extension ${shortId(id)}`);
      continue;
    }
    if (!entry.enabled) {
      notes.push(`dropped turned-off Extension ${entry.name}`);
      continue;
    }
    if (entry.tools.length === 0) {
      notes.push(`dropped hook/UI-only Extension ${entry.name}`);
      continue;
    }
    known = true;
    selected.add(entry.name);
  }
  if (!known) {
    // Neither list said anything about plugins: the Agent inherited Pi's discovery, one plugin per
    // enabled tool provider. That is exactly "every plugin" now.
    for (const name of catalogs.plugins.keys()) selected.add(name);
  }
  const toggleTools = new Set<string>(
    Object.values(AGENT_TOGGLE_TOOLS).map((toggle) => toggle.tool),
  );
  const refused = new Set<string>();
  for (const name of excluded) {
    // An excluded toggle is the switch above, not a plugin to remove.
    if (toggleTools.has(name)) continue;
    const plugin = catalogs.pluginByTool.get(name);
    if (plugin !== undefined) refused.add(plugin);
  }
  for (const name of refused) {
    if (selected.delete(name)) notes.push(`dropped plugin ${name} (its tools were excluded)`);
  }
  for (const toggle of Object.values(AGENT_TOGGLE_TOOLS)) selected.delete(toggle.plugin);
  // A toggle's plugin is not part of the list: the switch states it.
  const togglePlugins = new Set<string>(
    Object.values(AGENT_TOGGLE_TOOLS).map((toggle) => toggle.plugin),
  );
  const everyPlugin = [...catalogs.plugins.keys()].filter(
    (name) => !refused.has(name) && !togglePlugins.has(name),
  );
  if (selected.size === 0 && everyPlugin.length === 0) return [];
  // Omission means "every plugin this server may load", so it is only the same answer when no
  // plugin was refused: with an exclusion the selection has to be stated.
  if (
    refused.size === 0 &&
    everyPlugin.length === selected.size &&
    everyPlugin.every((name) => selected.has(name))
  ) {
    return undefined;
  }
  return [...selected].filter((name) => catalogs.plugins.has(name)).sort();
}

/**
 * The MCP selection. `mcp__` names in an allow list become an allow map of the servers and tools
 * they name; `mcp__` patterns in an exclusion list become an allow map of the servers that are
 * left. Neither list means every configured server, which is what the Agent reached before.
 */
function mcpFor(
  allowed: readonly string[] | undefined,
  excluded: readonly string[],
  launchConstraints: unknown,
  catalogs: AgentMigrationCatalogs,
  notes: string[],
): AgentMcpSelection | undefined {
  const configured = configuredMcpServers(launchConstraints, catalogs);
  const byNamespace = new Map(configured.map((name) => [agentMcpNamespace(name), name]));
  const select = (pattern: string): AgentMcpSelection | undefined => {
    if (!pattern.startsWith("mcp__") || pattern === "mcp__*") return undefined;
    const rest = pattern.slice("mcp__".length);
    const split = rest.indexOf("__");
    const namespace = `mcp__${split === -1 ? rest : rest.slice(0, split)}`;
    const server = byNamespace.get(namespace);
    if (!server) {
      notes.push(
        `dropped MCP tool ${pattern} (no server named ${namespace.slice(5)} is configured)`,
      );
      return undefined;
    }
    const tool = split === -1 ? "" : rest.slice(split + 2);
    if (!tool || tool === "*") return { [server]: "all" };
    return { [server]: [tool] };
  };
  if (allowed !== undefined) {
    const selection: Record<string, AgentMcpTools> = {};
    for (const entry of allowed) {
      if (!entry.startsWith("mcp__")) continue;
      const part = select(entry);
      if (!part) continue;
      for (const [server, tools] of Object.entries(part)) {
        if (tools === "all" || selection[server] === "all") selection[server] = "all";
        else selection[server] = [...new Set([...(selection[server] ?? []), ...tools])];
      }
    }
    // A tool an exclusion refuses cannot be part of a grant: state the rest of the server's tools
    // instead, which is the only way to keep one tool out of a selection.
    for (const entry of excluded) {
      const part = select(entry);
      if (!part) continue;
      for (const [server, tools] of Object.entries(part)) {
        if (tools === "all") {
          notes.push(`dropped listed tools of ${server} (the whole server was excluded)`);
          delete selection[server];
          continue;
        }
        // Remove from what is selected now, not from the server's whole list: two exclusions on
        // one server must both hold.
        const current = selection[server];
        const kept = (
          current === "all" ? (catalogs.mcpServerTools.get(server) ?? []) : (current ?? [])
        ).filter((tool) => !tools.includes(tool));
        if (kept.length === 0) {
          notes.push(
            `dropped MCP tool ${tools.join(", ")} and no other tool is known for ${server}`,
          );
          delete selection[server];
          continue;
        }
        selection[server] = kept;
        notes.push(
          `listed ${server}'s ${kept.length} other tools instead of all but ${tools.join(", ")}`,
        );
      }
    }
    return Object.fromEntries(Object.entries(selection).sort(([a], [b]) => a.localeCompare(b)));
  }
  const refusedNamespaces = new Set(
    excluded
      .filter((entry) => entry.startsWith("mcp__") && entry.endsWith("__*"))
      .map((entry) => entry.slice(0, -"__*".length)),
  );
  if (refusedNamespaces.size === 0) return undefined;
  const kept = configured.filter((name) => !refusedNamespaces.has(agentMcpNamespace(name)));
  const selection: Record<string, AgentMcpTools> = {};
  for (const name of kept) selection[name] = "all";
  notes.push(
    `stated ${kept.length} MCP server(s) instead of every server minus ${refusedNamespaces.size} excluded`,
  );
  return Object.fromEntries(Object.entries(selection).sort(([a], [b]) => a.localeCompare(b)));
}

/**
 * Servers an Agent could reach: the user scope plus the workspaces it may launch in. With no
 * workspace restriction that is every workspace this server knows, because the Agent may run in
 * any of them.
 */
function configuredMcpServers(
  launchConstraints: unknown,
  catalogs: AgentMigrationCatalogs,
): string[] {
  const allowedWorkspaces =
    isRecord(launchConstraints) && Array.isArray(launchConstraints.allowedWorkspaceIds)
      ? launchConstraints.allowedWorkspaceIds.filter((id): id is string => typeof id === "string")
      : undefined;
  const names = new Set(catalogs.userMcpServers);
  for (const [workspaceId, servers] of catalogs.workspaceMcpServers) {
    if (allowedWorkspaces !== undefined && !allowedWorkspaces.includes(workspaceId)) continue;
    for (const name of servers) names.add(name);
  }
  return [...names];
}

/** Skills by name (a Skill's folder), and the two context toggles as positive booleans. */
function contextFor(resources: NonNullable<V1Definition["resources"]>): AgentContext | undefined {
  const skills =
    resources.skillPaths === undefined
      ? undefined
      : [
          ...new Set(
            resources.skillPaths
              .map((path) => path.split(/[/\\]/).filter(Boolean).at(-2) ?? "")
              .filter(Boolean),
          ),
        ].sort();
  const context: AgentContext = {
    ...(skills === undefined ? {} : { skills }),
    ...(resources.noContextFiles === true ? { contextFiles: false } : {}),
    ...(resources.noSessionHistory === true ? { sessionHistory: false } : {}),
  };
  return Object.keys(context).length === 0 ? undefined : context;
}

function shortId(id: string): string {
  return id.length > 24 ? `${id.slice(0, 24)}…` : id;
}
