import {
  createCodemodeExtension,
  createMcpExtension,
  createToolSearchExtension,
  type InlineExtension,
} from "@earendil-works/pi-coding-agent";
import type { SandboxMcpOptions } from "./sandbox-mcp.js";

import { createLogger } from "./logger.js";

const log = createLogger({ base: { component: "host_mcp" } });

/** Pi resolves `additionalExtensionPaths: ["builtin:<name>"]` against named `builtin: true` factories. */
export const BUILTIN_EXTENSION_PATH_PREFIX = "builtin:";

/**
 * Pi 0.99 built-ins Oppi can supply. Names match upstream's `builtin:<name>`
 * settings (`-builtin:mcp` still disables one). Note the hyphen in `tool-search`.
 */
export const MCP_BUILTIN_NAMES = ["mcp", "codemode", "tool-search"] as const;
export type McpBuiltinName = (typeof MCP_BUILTIN_NAMES)[number];

export function isBuiltinExtensionPath(path: string): boolean {
  return path.startsWith(BUILTIN_EXTENSION_PATH_PREFIX);
}

/** Sandboxes run no agent-written code on the host, so they never get codemode. */
const SANDBOX_MCP_BUILTIN_NAMES: readonly McpBuiltinName[] = ["mcp", "tool-search"];

/**
 * Built-in extensions a session may load: all three for managed host sessions, none
 * otherwise. `-builtin:<name>` in Pi's `extensions` setting still disables one.
 *
 * Managed sandbox sessions get `mcp` (built with `sandbox-mcp.ts`: owner-picked
 * servers, stdio in the VM) and `tool-search`, but not `codemode`: its scripts are
 * model-written code running in this host process. Sandbox servers reach their tools
 * through `tool_search` instead. Pi TUI mirror sessions are terminal-owned, so their
 * runtime is left to the terminal's own Pi.
 */
export function availableMcpBuiltinNames(input: {
  managed: boolean;
  sandbox: boolean;
}): readonly McpBuiltinName[] {
  if (!input.managed) return [];
  return input.sandbox ? SANDBOX_MCP_BUILTIN_NAMES : MCP_BUILTIN_NAMES;
}

/**
 * Managed sessions must never launch the host browser. OAuth for MCP servers
 * can use the host's `pi mcp login` or the session's paste-redirect dialog;
 * credentials land in Pi's shared `mcp-auth.json`. The URL is logged without
 * query/fragment (it carries OAuth
 * state and PKCE material).
 */
function suppressHostBrowser(url: string): void {
  let target = "unparseable URL";
  try {
    const parsed = new URL(url);
    target = `${parsed.origin}${parsed.pathname}`;
  } catch {
    // Keep the placeholder; never log the raw value.
  }
  log.warn("mcp.open_url_suppressed", {
    target,
    hint: "Run `pi mcp login <server>` on the host to sign in.",
  });
}

const FACTORIES: Record<McpBuiltinName, (sandbox?: SandboxMcpOptions) => InlineExtension> = {
  mcp: (sandbox) => ({
    name: "mcp",
    builtin: true,
    replaceable: true,
    factory: createMcpExtension({ ...sandbox, openUrl: suppressHostBrowser }),
  }),
  codemode: () => ({
    name: "codemode",
    builtin: true,
    replaceable: true,
    factory: createCodemodeExtension(),
  }),
  "tool-search": () => ({
    name: "tool-search",
    builtin: true,
    replaceable: true,
    factory: createToolSearchExtension(),
  }),
};

/** Sandbox sessions must pass `sandbox`: it replaces Pi's MCP config loading and transports. */
export function createMcpBuiltinExtensions(
  names: readonly McpBuiltinName[],
  sandbox?: SandboxMcpOptions,
): InlineExtension[] {
  return names.map((name) => FACTORIES[name](sandbox));
}
