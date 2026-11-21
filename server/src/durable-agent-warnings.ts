/**
 * What a durable session tells its owner about an Agent it could not fully honour.
 *
 * A durable session has no classic extension registry: a plugin or Skill the Agent names may have
 * no version it can load. Saying so is part of the answer, since a session that quietly runs with
 * less than its definition names is worse than one that reports the gap.
 */
import {
  missingDurablePlugins,
  missingAgentSkillsWarning,
  skippedPluginsWarning,
  type CompiledAgentCapabilities,
} from "./agent-capabilities.js";
import type { PluginRuntime } from "./plugin-runtimes.js";

/** The package names a durable host can load: its packages, plus Oppi's built-ins for `runtime`. */
export function durableLoadablePlugins(
  runtime: {
    readonly loadedPackages: readonly { name: string }[];
    builtInsFor?: (which: PluginRuntime) => readonly { readonly name: string }[];
  },
  which: PluginRuntime,
): string[] {
  return [
    ...runtime.loadedPackages.map((plugin) => plugin.name),
    // The owner packages built into Oppi (`background-jobs`) load from the harness, not from
    // `loadedPackages`, and they are exactly what most Agents name. A stand-in runtime in a test
    // has no built-ins to report. `secret` is not one of them: it is a classic-only Pi extension,
    // so a durable session naming it rightly warns.
    ...(runtime.builtInsFor?.(which) ?? []).map((extension) => extension.name),
  ];
}

/** The warnings a durable session records for an Agent's compile and the resources it loaded. */
export function durableAgentWarnings(input: {
  readonly compiled: CompiledAgentCapabilities | undefined;
  readonly loadablePlugins: readonly string[];
  readonly missingSkills?: readonly string[];
}): string[] {
  const skipped = skippedPluginsWarning(
    missingDurablePlugins(input.compiled?.plugins, input.loadablePlugins),
  );
  const skills = missingAgentSkillsWarning(input.missingSkills ?? []);
  return [
    ...(input.compiled?.warnings ?? []),
    ...(skipped ? [skipped] : []),
    ...(skills ? [skills] : []),
  ];
}
