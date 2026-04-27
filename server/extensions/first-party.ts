import type { Workspace } from "../src/types.js";

/**
 * Server-managed extension names.
 *
 * permission-gate stays inline because it is backed by Oppi's policy server.
 * ask, voice, and subagents now load from reloadable file-based extensions.
 */
export const MANAGED_EXTENSION_NAMES = ["permission-gate"] as const;

export type ManagedExtensionName = (typeof MANAGED_EXTENSION_NAMES)[number];
export type FirstPartyExtensionName = "ask" | "subagents" | "voice";

/** First-party extension names exposed to the workspace UI. */
export const FIRST_PARTY_EXTENSION_NAMES: readonly FirstPartyExtensionName[] = [
  "ask",
  "subagents",
  "voice",
];

const MANAGED_EXTENSION_NAME_SET = new Set<string>(MANAGED_EXTENSION_NAMES);

/**
 * Managed by oppi-server itself, not loaded from pi file-based extension paths.
 *
 * - permission-gate is replaced by the server's policy engine
 * - ask, subagents, and voice are first-party but now load from reloadable files
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

  return allowedNames.includes(extensionName);
}
