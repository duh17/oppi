import { DefaultPackageManager, type SettingsManager } from "@earendil-works/pi-coding-agent";
import { basename, dirname } from "node:path";

import { AgentConfigurationError } from "./agent-launch-errors.js";
import { skillFolderName } from "./agent-capabilities.js";
import { keepAutoDiscoveryOffHost } from "./sandbox-host-extensions.js";

/** Scopes that can satisfy an Agent's plugin selection for a launch cwd. */
const SELECTABLE_EXTENSION_SCOPES = new Set(["user", "project"]);

/**
 * Resolve an Agent's plugin names to the classic Pi extension paths they name.
 *
 * A name is a package's name as `oppi extensions list` shows it: the file name of a single-file
 * extension, else the folder holding its `index.ts` (for `plugins/background-jobs/index.ts`,
 * `background-jobs`). Undefined means every extension Pi discovers, which is what an Agent with
 * no plugin selection gets. A name nothing resolves is an `agent_plugins_unavailable` launch
 * failure: silently starting without a plugin the Agent needs is worse than not starting.
 */
export async function resolveAgentPluginPaths(
  pluginNames: readonly string[] | undefined,
  cwd: string,
  agentDir: string,
  settingsManager: SettingsManager,
): Promise<string[] | undefined> {
  if (pluginNames === undefined) return undefined;
  if (pluginNames.length === 0) return [];

  const packageManager = new DefaultPackageManager({ cwd, agentDir, settingsManager });
  // Only Skills come from the `.agents/skills` walk, which a sandbox guest can make endless.
  keepAutoDiscoveryOffHost(packageManager);
  const resolved = await packageManager.resolve(async () => "skip");
  const pathsByName = new Map<string, string[]>();
  for (const resource of resolved.extensions) {
    if (!SELECTABLE_EXTENSION_SCOPES.has(resource.metadata.scope)) continue;
    const name = extensionNameFromPath(resource.path);
    const paths = pathsByName.get(name) ?? [];
    paths.push(resource.path);
    pathsByName.set(name, paths);
  }
  const selected: string[] = [];
  const unavailable: string[] = [];
  for (const name of new Set(pluginNames)) {
    const paths = pathsByName.get(name);
    if (!paths?.length) {
      unavailable.push(name);
      continue;
    }
    for (const path of paths) if (!selected.includes(path)) selected.push(path);
  }
  if (unavailable.length > 0) {
    throw new AgentConfigurationError(
      "agent_plugins_unavailable",
      { unavailablePlugins: unavailable },
      `Selected Agent plugin is unavailable: ${unavailable.join(", ")}`,
    );
  }
  return selected;
}

/** An extension's name as the catalog shows it: its file, or the folder of its `index.*`. */
export function extensionNameFromPath(path: string): string {
  const withoutExtension = basename(path).replace(/\.(?:ts|js)$/, "");
  if (withoutExtension !== "index") return withoutExtension;
  return basename(dirname(path));
}

/** Pi's own paths for an Agent's named Skills, and the names nothing discovers. */
export interface ResolvedAgentSkillPaths {
  readonly paths: string[];
  readonly missing: string[];
}

/**
 * Resolve an Agent's Skill names to the `SKILL.md` paths Pi loads, **including Skills its settings
 * disable**. Pi's enabled discovery drops a disabled Skill before an override can keep it, so an
 * Agent that names `finance-inbox` would silently lose it; the resolved list still has its path,
 * and a session loads exactly the named paths (`noSkills` plus `additionalSkillPaths`).
 *
 * Undefined means the Agent named no Skills: Pi discovery decides, and this resolves nothing.
 */
export async function resolveAgentSkillPaths(
  skillNames: readonly string[] | undefined,
  cwd: string,
  agentDir: string,
  settingsManager: SettingsManager,
): Promise<ResolvedAgentSkillPaths | undefined> {
  if (skillNames === undefined) return undefined;
  const wanted = [...new Set(skillNames)];
  if (wanted.length === 0) return { paths: [], missing: [] };
  const packageManager = new DefaultPackageManager({ cwd, agentDir, settingsManager });
  // Only Skills come from the `.agents/skills` walk, which a sandbox guest can make endless.
  keepAutoDiscoveryOffHost(packageManager);
  const resolved = await packageManager.resolve(async () => "skip");
  const pathByName = new Map<string, string>();
  for (const resource of resolved.skills) {
    const name = skillFolderName(resource.path);
    if (name && !pathByName.has(name)) pathByName.set(name, resource.path);
  }
  const paths: string[] = [];
  const missing: string[] = [];
  for (const name of wanted) {
    const path = pathByName.get(name);
    if (path === undefined) missing.push(name);
    else if (!paths.includes(path)) paths.push(path);
  }
  return { paths, missing };
}
