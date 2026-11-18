import { defineRegistry } from "@earendil-works/chord";
import type { Extension, RegistrySnapshot, ToolRegistration } from "@earendil-works/pi-durable";
import type { RestorableSurface } from "./durable-surface.js";
import { pluginRuntimes, type PluginRuntime } from "./plugin-runtimes.js";

/**
 * `oppi/v1`: Oppi's plugin API, version 1. A plugin's `server.ts` default-exports a facet that
 * contributes one durable extension:
 *
 * ```ts
 * import { defineExtension, defineFacet, defineTool, Extensions } from "oppi/v1";
 * import { obj, str } from "oppi/v1/schema";
 *
 * const hello = defineTool({ name: "hello", description: "Say hello", parameters: obj({ to: str() }),
 *   execute: async ({ to }) => ({ output: [{ type: "text", text: `Hello, ${to}` }] }) });
 *
 * export default defineFacet((host, self) => {
 *   self.contribute(Extensions, defineExtension({ name: "hello", tools: [hello], runtimes: ["host"] }));
 * });
 * ```
 *
 * The plugin host hands plugins the server's own instance of this module and of the packages it
 * re-exports, so a plugin's tasks and documents are the Harness's. When Chord's or pi-durable's API
 * changes, this module absorbs it and plugins written against v1 keep working.
 * @public
 */

/**
 * Chord's facet: a plugin's declarations on a host (`self.contribute`).
 * @public
 */
export { defineFacet, type Facet, type FacetHost, type FacetSelf } from "@earendil-works/chord";
/** pi-durable's authoring API: tools, tasks, hooks, sections, wraps, documents. */
export * from "@earendil-works/pi-durable";
/** What only Oppi provides: its host (`oppiHost()`), extension UI dialogs and cards. */
export * from "./durable-extension-api.js";

export type { PluginRuntime } from "./plugin-runtimes.js";
/** Sidebar entries and their list screens (built-in plugins only). */
export {
  defineScreen,
  LOADING_PAGE,
  SCREEN_REFRESH_ACTION,
  Sidebar,
  type ScreenActArgs,
  type ScreenActResult,
  type ScreenDefinition,
  type SidebarContribution,
} from "./plugin-screens.js";
export type * from "./types/screens.js";
/** A message's typed text without the context block the server puts before it for the model. */
export { stripPromptContext } from "./prompt-context.js";

/** A durable extension with the runtimes whose sessions may select it, and the panels it restores. */
export interface PluginExtension<
  Tool extends ToolRegistration = ToolRegistration,
> extends Extension<Tool> {
  readonly runtimes: readonly PluginRuntime[];
  readonly surfaces: readonly RestorableSurface[];
}

/**
 * pi-durable's `defineExtension`, plus `runtimes`: the runtimes whose sessions may select it, by
 * default `["host"]`. Code always runs in the server process; list `"sandbox"` only when every
 * command and file access goes through `api.env`. `surfaces` lists the panels (`surface()` with a
 * `load`) the host publishes again whenever a conversation that selects the extension attaches.
 * @public
 */
export function defineExtension<Tool extends ToolRegistration = ToolRegistration>(
  extension: Extension<Tool> & {
    readonly runtimes?: readonly PluginRuntime[];
    readonly surfaces?: readonly RestorableSurface[];
  },
): PluginExtension<Tool> {
  return {
    ...extension,
    runtimes: pluginRuntimes(extension.runtimes),
    surfaces: extension.surfaces ?? [],
  };
}

/**
 * Oppi's registry of durable extensions. A plugin's facet contributes one extension to it; the
 * server composes every contribution into the registry its Harness reads.
 */
export const Extensions = defineRegistry<Extension, RegistrySnapshot>("oppi.extensions", {
  version: 1,
});
