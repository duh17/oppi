import type { ToolDisplay } from "./types.js";
function asRecord(v: unknown): Record<string, unknown> | undefined {
  return typeof v === "object" && v !== null ? (v as Record<string, unknown>) : undefined;
}
/** One producer-only name rule. Pi's public definitions drop raw MCP titles,
 * icons and serverInfo; do not guess titles from description or serverInfo.name.
 * See createMcpToolDefinition/createMcpToolName in Pi's MCP adapter.
 */
export function resolveToolDisplay(
  name: string,
  definition?: { label?: string; namespace?: { name: string } },
  details?: unknown,
  configuredServerNames: readonly string[] = [],
): ToolDisplay | undefined {
  let title: string | undefined;
  let group: string | undefined;
  if (definition?.namespace?.name.startsWith("mcp__") && definition.label) {
    const slash = definition.label.indexOf("/");
    if (slash > 0 && slash < definition.label.length - 1) {
      group = definition.label.slice(0, slash);
      title = definition.label.slice(slash + 1);
    }
  }
  const result = asRecord(details);
  if (!title && typeof result?.server === "string" && typeof result.tool === "string") {
    group = result.server;
    title = result.tool;
  }
  if (!title && name.startsWith("mcp__")) {
    const separator = name.indexOf("__", 5);
    if (separator > 5 && separator + 2 < name.length) {
      group = name.slice(5, separator);
      // Pi replaces each non-identifier character with `_`. Restore a configured
      // spelling only for a unique match; never guess across colliding names.
      const matches = configuredServerNames.filter(
        (server) => server.replace(/[^A-Za-z0-9_]/g, "_") === group,
      );
      if (matches.length === 1) group = matches[0];
      title = name.slice(separator + 2);
    }
  }
  if (!title?.trim() || (title === name && !group)) return undefined;
  return { title, ...(group?.trim() ? { group } : {}) };
}
