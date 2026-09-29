import {
  createCodemodeExtension,
  createMcpExtension,
  createToolSearchExtension,
  type InlineExtension,
} from "@earendil-works/pi-coding-agent";

import { createLogger } from "./logger.js";

const log = createLogger({ base: { component: "host_mcp" } });

/** Pi resolves `additionalExtensionPaths: ["builtin:<name>"]` against named `builtin: true` factories. */
export const BUILTIN_EXTENSION_PATH_PREFIX = "builtin:";

/**
 * Pi 0.99 built-ins Oppi can supply. Names match upstream's `builtin:<name>`
 * settings (`-builtin:mcp` still disables one). Note the hyphen in `tool-search`.
 */
export const HOST_MCP_BUILTIN_NAMES = ["mcp", "codemode", "tool-search"] as const;
export type HostMcpBuiltinName = (typeof HOST_MCP_BUILTIN_NAMES)[number];

export function isBuiltinExtensionPath(path: string): boolean {
  return path.startsWith(BUILTIN_EXTENSION_PATH_PREFIX);
}

/**
 * Built-in extensions a session may load: all three for managed host sessions,
 * none otherwise. `-builtin:<name>` in Pi's `extensions` setting still disables one.
 *
 * Sandbox workspaces never get them: MCP connects (and spawns stdio servers on
 * the host) at session_start, before any tool approval, and host-side extension
 * tools are not sandbox confinement. Pi TUI mirror sessions are terminal-owned,
 * so their runtime is left to the terminal's own Pi.
 */
export function availableHostMcpBuiltinNames(input: {
  sandbox: boolean;
  managed: boolean;
}): readonly HostMcpBuiltinName[] {
  if (!input.managed || input.sandbox) return [];
  return HOST_MCP_BUILTIN_NAMES;
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

const FACTORIES: Record<HostMcpBuiltinName, () => InlineExtension> = {
  mcp: () => ({
    name: "mcp",
    builtin: true,
    replaceable: true,
    factory: createMcpExtension({ openUrl: suppressHostBrowser }),
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

export function createHostMcpBuiltinExtensions(
  names: readonly HostMcpBuiltinName[],
): InlineExtension[] {
  return names.map((name) => FACTORIES[name]());
}
