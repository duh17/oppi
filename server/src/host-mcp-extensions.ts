import {
  createCodemodeExtension,
  createMcpExtension,
  createToolSearchExtension,
  type InlineExtension,
  type McpExtensionOptions,
} from "@earendil-works/pi-coding-agent";

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

/**
 * Built-in extensions a session may load: all three for managed sessions, none
 * otherwise. `-builtin:<name>` in Pi's `extensions` setting still disables one.
 *
 * Sandbox sessions get them too, but their MCP extension is built with the
 * sandbox options from `sandbox-mcp.ts` (owner-picked servers, stdio in the VM).
 * Codemode scripts run in QuickJS/WASM in this host process and reach only the
 * session's registered tools. Pi TUI mirror sessions are terminal-owned, so their
 * runtime is left to the terminal's own Pi.
 */
export function availableMcpBuiltinNames(managed: boolean): readonly McpBuiltinName[] {
  return managed ? MCP_BUILTIN_NAMES : [];
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

/** A sandbox session's MCP config loading and transports (`sandbox-mcp.ts`). */
export interface SandboxMcpBuiltins {
  mcp: Pick<McpExtensionOptions, "loadConfig" | "createTransport">;
}

const FACTORIES: Record<McpBuiltinName, (sandbox?: SandboxMcpBuiltins) => InlineExtension> = {
  mcp: (sandbox) => ({
    name: "mcp",
    builtin: true,
    replaceable: true,
    factory: createMcpExtension({ ...sandbox?.mcp, openUrl: suppressHostBrowser }),
  }),
  codemode: (sandbox) => ({
    name: "codemode",
    builtin: true,
    replaceable: true,
    // Scripts run in this host process; in a sandbox they get no `models` catalog or
    // classifier calls with host credentials.
    factory: createCodemodeExtension(sandbox ? { models: false } : undefined),
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
  sandbox?: SandboxMcpBuiltins,
): InlineExtension[] {
  return names.map((name) => FACTORIES[name](sandbox));
}
