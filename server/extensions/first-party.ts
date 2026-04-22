import type { Workspace } from "../src/types.js";

/**
 * Server-managed extension names.
 *
 * Includes legacy alias `spawn_agent` for backward compatibility with saved
 * workspace extension allowlists.
 */
export const MANAGED_EXTENSION_NAMES = [
  "permission-gate",
  "ask",
  "subagents",
  "spawn_agent",
] as const;

export type ManagedExtensionName = (typeof MANAGED_EXTENSION_NAMES)[number];
export type FirstPartyExtensionName = "ask" | "subagents";

/** First-party extension names exposed to the workspace UI. */
export const FIRST_PARTY_EXTENSION_NAMES: readonly FirstPartyExtensionName[] = ["ask", "subagents"];

const MANAGED_EXTENSION_NAME_SET = new Set<string>(MANAGED_EXTENSION_NAMES);

const LEGACY_EXTENSION_ALIASES: Partial<Record<FirstPartyExtensionName, readonly string[]>> = {
  subagents: ["spawn_agent"],
};

/**
 * Managed by oppi-server itself, not loaded from pi host extension directories.
 *
 * - permission-gate is replaced by the server's policy engine
 * - ask is a first-party factory extension so iOS AskCard behavior stays aligned
 * - subagents is a first-party factory extension backed by SessionManager
 */
export function isManagedExtensionName(name: string): boolean {
  return MANAGED_EXTENSION_NAME_SET.has(name);
}

/**
 * First-party factory extensions default to enabled.
 *
 * If a workspace sets an explicit `extensions` allowlist, that list becomes
 * authoritative. This means `extensions: []` disables all optional extensions,
 * including first-party ones like ask and subagents.
 */
export function isWorkspaceExtensionEnabled(
  workspace: Workspace | undefined,
  extensionName: FirstPartyExtensionName,
): boolean {
  const allowedNames = workspace?.extensions;
  if (allowedNames === undefined) {
    return true;
  }

  if (allowedNames.includes(extensionName)) {
    return true;
  }

  const aliases = LEGACY_EXTENSION_ALIASES[extensionName] ?? [];
  return aliases.some((alias) => allowedNames.includes(alias));
}
