import type { AgentMigrationCatalogs } from "../../src/agent-definition-migration.js";

/** No extension, plugin, or MCP catalog: a migration that only has to read the stored row. */
export function emptyMigrationCatalogs(): AgentMigrationCatalogs {
  return {
    extensions: new Map(),
    pluginByTool: new Map(),
    plugins: new Map(),
    userMcpServers: [],
    workspaceMcpServers: new Map(),
    mcpServerTools: new Map(),
  };
}
