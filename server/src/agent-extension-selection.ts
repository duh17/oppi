import { DefaultPackageManager, type SettingsManager } from "@earendil-works/pi-coding-agent";

import { AgentConfigurationError } from "./agent-launch-errors.js";
import { serverResourceId } from "./server-resource-id.js";

/** Scopes that can satisfy an Agent's exact Extension selection for a launch cwd. */
const SELECTABLE_EXTENSION_SCOPES = new Set(["user", "project"]);

/**
 * Resolve Agent-selected Extension IDs to host paths for the launch cwd.
 *
 * Exact Agent selections may target Extensions discovered as either user or
 * project resources. Project scope matters when a workspace re-enables an
 * Extension that is disabled at user scope — the package manager then reports
 * the path under project scope for that cwd.
 */
export async function resolveSelectedAgentExtensionPaths(
  extensionIds: string[] | undefined,
  cwd: string,
  agentDir: string,
  settingsManager: SettingsManager,
): Promise<string[] | undefined> {
  if (extensionIds === undefined) return undefined;
  if (extensionIds.length === 0) return [];

  const packageManager = new DefaultPackageManager({ cwd, agentDir, settingsManager });
  const resolved = await packageManager.resolve(async () => "skip");
  const pathsById = new Map(
    resolved.extensions
      .filter((resource) => SELECTABLE_EXTENSION_SCOPES.has(resource.metadata.scope))
      .map((resource) => [serverResourceId("extension", resource.path), resource.path]),
  );
  const selectedPaths: string[] = [];
  const unavailableExtensions: string[] = [];
  for (const extensionId of new Set(extensionIds)) {
    const path = pathsById.get(extensionId);
    if (!path) {
      unavailableExtensions.push(extensionId);
      continue;
    }
    selectedPaths.push(path);
  }
  if (unavailableExtensions.length > 0) {
    throw new AgentConfigurationError(
      "agent_extensions_unavailable",
      { unavailableExtensions },
      `Selected Agent Extension is unavailable: ${unavailableExtensions.join(", ")}`,
    );
  }
  return selectedPaths;
}
