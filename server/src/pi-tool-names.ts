/**
 * The two tool names Pi's own extensions register off, and that its `defaultTools` setting turns on.
 *
 * They live in a module with no Pi import so that both readers agree on one list: the Agent
 * compiler (`agent-capabilities.ts`), which derives `codemode` and `tool_search` from MCP exposures
 * and from an Agent's own tool set, and `pi-global-config.ts`, which reads the Pi Tools setting and
 * loads Pi's dist.
 */
export const PI_DISCOVERY_TOOL_NAMES = ["codemode", "tool_search"] as const;
