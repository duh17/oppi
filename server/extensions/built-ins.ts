import type { Workspace } from "../src/types.js";

/** Extension names implemented directly by Oppi server. */
export type BuiltInExtensionName = "ask" | "subagents" | "voice" | "oppi-admin";

/** Policy-backed names that must never be loaded from host extension paths. */
export const MANAGED_EXTENSION_NAMES = ["permission-gate"] as const;

/** Built-in tools exposed in the workspace extension picker. */
export const BUILT_IN_EXTENSION_NAMES: readonly BuiltInExtensionName[] = [
  "ask",
  "subagents",
  "voice",
  "oppi-admin",
];

const MANAGED_EXTENSION_NAME_SET = new Set<string>(MANAGED_EXTENSION_NAMES);
const BUILT_IN_EXTENSION_NAME_SET = new Set<string>(BUILT_IN_EXTENSION_NAMES);

export function isManagedExtensionName(name: string): boolean {
  return MANAGED_EXTENSION_NAME_SET.has(name);
}

export function isBuiltInExtensionName(name: string): name is BuiltInExtensionName {
  return BUILT_IN_EXTENSION_NAME_SET.has(name);
}

/**
 * Built-in extension enablement.
 *
 * Built-ins are off unless the workspace explicitly lists them. This affects
 * Oppi server sessions only; it does not install anything into standalone pi.
 */
export function isWorkspaceBuiltInExtensionEnabled(
  workspace: Workspace | undefined,
  extensionName: BuiltInExtensionName,
): boolean {
  return workspace?.extensions?.includes(extensionName) ?? false;
}
