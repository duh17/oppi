/**
 * The runtimes an extension declares it is safe in, shared by durable plugins (`runtimes`) and
 * classic Pi packages (`oppi.classicRuntimes`). A leaf module: the classic path reads it without
 * loading `oppi/v1`, which re-exports pi-durable.
 */

/** Where a session runs its tools: on the server's host, or in a workspace's sandbox VM. */
export type PluginRuntime = "host" | "sandbox";

const RUNTIMES: readonly PluginRuntime[] = ["host", "sandbox"];

/** `runtimes` checked, `["host"]` when unset. Throws for an empty, unknown, or repeated runtime. */
export function pluginRuntimes(runtimes: unknown): readonly PluginRuntime[] {
  if (runtimes === undefined) return ["host"];
  if (
    !Array.isArray(runtimes) ||
    runtimes.length === 0 ||
    runtimes.some((runtime) => !RUNTIMES.includes(runtime as PluginRuntime)) ||
    new Set(runtimes).size !== runtimes.length
  )
    throw new Error('`runtimes` must list "host", "sandbox", or both, once each');
  return runtimes as PluginRuntime[];
}
