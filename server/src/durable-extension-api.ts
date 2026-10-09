import type { Extension } from "@earendil-works/pi-durable";

/** Execution runtimes a durable extension may load in. */
export type DurableExtensionRuntime = "host" | "sandbox";

/**
 * The default export of a package's `durable.ts`. Package code imports this module as
 * `oppi/durable`; the loader aliases it, and `@earendil-works/pi-durable`, to the server's
 * own copies so documents and tasks the extension defines are the Harness's own.
 */
export interface DurableExtensionModule {
  /** A plain pi-durable extension: tools, sections, hooks, wraps, tasks. */
  readonly extension: Extension;
  /**
   * Runtimes whose sessions may select it. Default `["host"]`. Code always runs in the server
   * process; only list `"sandbox"` when every command and file access goes through `api.env`.
   */
  readonly runtimes?: readonly DurableExtensionRuntime[];
}

/**
 * Imported by package code through the `oppi/durable` alias, never by the server itself.
 * @public
 */
export function defineDurableExtension(module: DurableExtensionModule): DurableExtensionModule {
  return module;
}
