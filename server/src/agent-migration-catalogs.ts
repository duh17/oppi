/**
 * What the one-time Agent v1 → v2 migration needs to know about this server: which extensions and
 * plugins provide which tools, and which MCP servers each scope configures. Built only when a
 * stored Agent still holds the v1 shape, and only from what is stored at that moment.
 */
import { join } from "node:path";

import type { AgentMigrationCatalogs } from "./agent-definition-migration.js";
import { mcpServerFacts } from "./durable-mcp.js";
import { readMcpDocument } from "./mcp-config.js";
import type { ServerExtensionSummary } from "./server-resource-service.js";
import type { Workspace } from "./types.js";
import { isRecord } from "./json-shape.js";

export async function buildAgentMigrationCatalogs(input: {
  extensions: readonly ServerExtensionSummary[];
  workspaces: readonly Workspace[];
  agentDir: string;
  dataDir: string;
}): Promise<AgentMigrationCatalogs> {
  const extensions = new Map<
    string,
    { name: string; enabled: boolean; tools: readonly string[] }
  >();
  const pluginByTool = new Map<string, string>();
  const plugins = new Map<string, string[]>();
  // Pi's own tools come from Pi, not from a plugin that wraps one of them.
  const piBuiltins = new Set(["read", "write", "edit", "bash", "ls", "find", "grep"]);
  // Only a package with a classic extension can be selected by name in a classic session; a
  // built-in plugin's tools are Oppi's own and are always there, so it is not an Agent's choice.
  const selectable = new Set(
    input.extensions.filter((row) => row.kinds.includes("pi-extension")).map((row) => row.name),
  );
  for (const row of input.extensions) {
    const tools = [...new Set([...(row.contributedTools ?? []), ...(row.plugin?.tools ?? [])])];
    extensions.set(row.id, { name: row.name, enabled: row.state === "on", tools });
    if (row.state !== "on" || !selectable.has(row.name)) continue;
    plugins.set(row.name, [...new Set([...(plugins.get(row.name) ?? []), ...tools])]);
    for (const tool of tools) {
      if (piBuiltins.has(tool) || !selectable.has(row.name)) continue;
      if (!pluginByTool.has(tool)) pluginByTool.set(tool, row.name);
    }
  }
  // A plugin with no tools is not something an Agent can select.
  for (const [name, tools] of plugins) if (tools.length === 0) plugins.delete(name);

  const userMcpServers = mcpServerNames(join(input.agentDir, "mcp.json"));
  const workspaceMcpServers = new Map<string, readonly string[]>();
  const mcpServerTools = new Map<string, readonly string[]>();
  const scopes: Array<{ cwd: string; names: readonly string[]; projectTrusted: boolean }> = [
    {
      cwd: input.workspaces[0]?.hostMount ?? input.agentDir,
      names: userMcpServers,
      projectTrusted: false,
    },
    ...input.workspaces.map((workspace) => ({
      cwd: workspace.hostMount,
      names: mcpServerNames(join(workspace.hostMount, ".pi", "mcp.json")),
      projectTrusted: true,
    })),
  ];
  for (const scope of scopes) {
    if (!scope.names.length) continue;
    // A server's last-known tool list comes from Oppi's cache, keyed by its config: the same
    // loader the sessions use, so a tool subset can name the tools the server actually has.
    for (const fact of await mcpServerFacts({
      agentDir: input.agentDir,
      cwd: scope.cwd,
      projectTrusted: scope.projectTrusted,
      dataDir: input.dataDir,
    })) {
      // One server can be configured in several scopes; any scope that has a cached list will do,
      // so a later scope with none never erases what an earlier one reported.
      const known = new Set([...(mcpServerTools.get(fact.name) ?? []), ...fact.tools]);
      if (known.size > 0) mcpServerTools.set(fact.name, [...known].sort());
    }
  }
  for (const workspace of input.workspaces) {
    workspaceMcpServers.set(
      workspace.id,
      mcpServerNames(join(workspace.hostMount, ".pi", "mcp.json")),
    );
  }

  return {
    extensions,
    pluginByTool,
    plugins,
    userMcpServers,
    workspaceMcpServers,
    mcpServerTools,
  };
}

function mcpServerNames(path: string): string[] {
  let document: Record<string, unknown>;
  try {
    document = readMcpDocument(path);
  } catch {
    return [];
  }
  const servers = isRecord(document.mcpServers) ? document.mcpServers : {};
  return Object.keys(servers).sort();
}
