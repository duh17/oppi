import type { Workspace } from "../src/types.js";

export const MANAGED_EXTENSION_NAMES = ["permission-gate", "ask", "spawn_agent"] as const;

export type ManagedExtensionName = (typeof MANAGED_EXTENSION_NAMES)[number];
export type FirstPartyExtensionName = Exclude<ManagedExtensionName, "permission-gate">;

/** First-party extension names exposed to the workspace UI. */
export const FIRST_PARTY_EXTENSION_NAMES: readonly FirstPartyExtensionName[] = [
  "ask",
  "spawn_agent",
];

const MANAGED_EXTENSION_NAME_SET = new Set<string>(MANAGED_EXTENSION_NAMES);

/**
 * Managed by oppi-server itself, not loaded from pi host extension directories.
 *
 * - permission-gate is replaced by the server's policy engine
 * - ask is a first-party factory extension so iOS AskCard behavior stays aligned
 * - spawn_agent is a first-party factory extension backed by SessionManager
 */
export function isManagedExtensionName(name: string): boolean {
  return MANAGED_EXTENSION_NAME_SET.has(name);
}

/**
 * First-party factory extensions default to enabled.
 *
 * If a workspace sets an explicit `extensions` allowlist, that list becomes
 * authoritative. This means `extensions: []` disables all optional extensions,
 * including first-party ones like ask and spawn_agent.
 */
export function isWorkspaceExtensionEnabled(
  workspace: Workspace | undefined,
  extensionName: FirstPartyExtensionName,
): boolean {
  const allowedNames = workspace?.extensions;
  if (allowedNames === undefined) {
    return true;
  }

  return allowedNames.includes(extensionName);
}
