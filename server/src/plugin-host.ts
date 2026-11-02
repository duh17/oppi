import * as chord from "@earendil-works/chord";
import * as chordContext from "@earendil-works/chord/context";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import * as chordDelta from "@earendil-works/chord/delta";
import * as chordNext from "@earendil-works/chord/next";
import {
  createHost,
  defineFacet,
  type Facet,
  type FacetHost,
  type FacetSelf,
  type Host,
  type HostError,
  type PluginFacet,
  type RegistryTable,
} from "@earendil-works/chord/next";
import * as piAi from "@earendil-works/pi-ai";
import { DefaultPackageManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import * as piDurable from "@earendil-works/pi-durable";
import {
  createRegistry,
  registryReader,
  type Extension,
  type Registry,
  type RegistryReader,
  type RegistrySnapshot,
} from "@earendil-works/pi-durable";
import * as piDurableEnv from "@earendil-works/pi-durable/env";
import * as piDurableEnvNode from "@earendil-works/pi-durable/env/node";
import * as piDurableTools from "@earendil-works/pi-durable/tools";
import * as piSchema from "@earendil-works/pi-schema";
import { createJiti } from "jiti";
import { homedir } from "node:os";
import { basename, isAbsolute, join, relative } from "node:path";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import * as oppiV1 from "./oppi-v1.js";
import { Extensions, pluginRuntimes, type PluginRuntime } from "./oppi-v1.js";
import * as oppiV1Schema from "./oppi-v1-schema.js";
import {
  discoverPackage,
  discoverPiPackage,
  discoverRoot,
  piPackageRoot,
  type DiscoveredPlugin,
  type DiscoveryProblem,
} from "./plugin-discovery.js";
import { serverResourceId } from "./server-resource-id.js";

const log = createLogger({ base: { component: "plugins" } });

/**
 * Oppi's plugin host: durable extensions as plugins in upstream Chord's layout
 * (`plugin-discovery.ts`), each `server.ts` a facet that contributes one extension to `Extensions`
 * (`oppi/v1`). A store-less Chord host (`createHost`) loads them; its core facet composes the
 * contributions with the server's own extensions into the registry snapshot the Harness reads
 * through pi-durable's `registryReader`. Per-session extensions (MCP) live in an overlay the host
 * owns, outside plugins.
 *
 * Roots, in precedence order: the built-in root (one package whose `chord.plugins` lists Oppi's
 * built-ins in prompt order), then the owner's: `<agentDir>/plugins/` and the enabled user-scope Pi
 * packages, resolved as Pi resolves classic extensions. Project-scope packages are never read: the
 * registry is shared by every session, and they need per-workspace trust.
 *
 * Clashes are decided before Chord sees the plugins: built-ins win over owner plugins, a plugin
 * already loaded over a new one, then listing order. The losing plugin is a load error and keeps its
 * previous code if it had any; Chord's own conflict rule (first by plugin name) would let a new
 * plugin push out a loaded one. Owner plugins may not take a tool of the server's own extensions;
 * built-ins may (background-jobs replaces CodingTools' `bash`). An owner package named like a
 * built-in is that built-in linked into Pi (a checkout's `ask`): skipped, and its classic IDs stand
 * for the built-in.
 */

export type PluginSource = "built-in" | "owner";

/** A plugin whose extension is installed. */
export interface LoadedPlugin {
  /** Its `package.json` name, or a single file's name. */
  readonly name: string;
  readonly source: PluginSource;
  readonly dir: string;
  /** Its `server` facet file. */
  readonly facet: string;
  /** A built-in the server cannot run without: never disabled, and fatal when it fails to load first. */
  readonly required: boolean;
  readonly extension: Extension;
  readonly runtimes: readonly PluginRuntime[];
  /** Server resource IDs of the classic extensions of its Pi package, as saved Agents select them. */
  readonly extensionIds: readonly string[];
}

export interface PluginIssue {
  /** The file or folder that failed. */
  readonly path: string;
  readonly message: string;
  /** The plugin, when the problem is one plugin's. */
  readonly plugin?: string;
}

/**
 * A plugin whose last load or reload failed. It may still be installed (`plugins`) with its
 * previous code; a plugin that never loaded is only here.
 */
interface PluginFailure {
  readonly name: string;
  readonly source: PluginSource;
  readonly dir: string;
  readonly facet: string | undefined;
  readonly required: boolean;
  readonly extensionIds: readonly string[];
  /** Every problem of that load, in order. */
  readonly message: string;
}

/** What a plugin's extension contributes, by name. */
export interface PluginContributions {
  readonly tools: string[];
  /** Hook handler names, grouped by the task they hook, in registration order. */
  readonly hooks: { task: string; handlers: string[] }[];
  /** Prompt section keys. */
  readonly sections: string[];
  /** The tool or section each wrap targets. */
  readonly wraps: ({ tool: string } | { section: string })[];
  readonly tasks: string[];
}

/** A plugin as the extension list shows it: installed, failed, or both (its old code kept). */
export interface PluginListing extends PluginContributions {
  readonly name: string;
  /** Its installed extension's name, which sessions select it by; absent when it never loaded. */
  readonly extension?: string;
  readonly source: PluginSource;
  readonly dir: string;
  readonly facet: string | undefined;
  /** Server resource IDs of the classic extensions of its Pi package. */
  readonly extensionIds: readonly string[];
  readonly required: boolean;
  /** Whether workspace sessions select its extension; false when it has none installed. */
  readonly enabled: boolean;
  readonly runtimes: readonly PluginRuntime[];
  /** Why its last load or reload failed. */
  readonly loadError?: string;
  /** A failed reload left its previous code installed. */
  readonly kept: boolean;
}

/** What `extension` contributes, read from the extension value itself. */
function contributionsOf(extension: Extension | undefined): PluginContributions {
  const hooks: { task: string; handlers: string[] }[] = [];
  for (const registration of extension?.hooks ?? []) {
    let group = hooks.find((known) => known.task === registration.task);
    if (!group) hooks.push((group = { task: registration.task, handlers: [] }));
    for (const handler of Object.keys(registration.handlers))
      if (!group.handlers.includes(handler)) group.handlers.push(handler);
  }
  return {
    tools: (extension?.tools ?? []).map((tool) => tool.name),
    hooks,
    sections: (extension?.sections ?? []).map((section) => section.key),
    wraps: (extension?.wraps ?? []).map((wrap) =>
      "tool" in wrap ? { tool: wrap.tool } : { section: wrap.section },
    ),
    tasks: (extension?.tasks ?? []).map((task) => task.definition.name),
  };
}

/** What one load or reload did. */
export interface PluginReport {
  /** Installed from this load; a plugin installed before had its code replaced in place. */
  readonly loaded: readonly LoadedPlugin[];
  /** Failed to load this time; its previous code stays installed. */
  readonly kept: readonly LoadedPlugin[];
  /** Extension names installed before and provided by no plugin now: uninstalled. */
  readonly removed: readonly string[];
  /** Not loaded on purpose: an owner package that is one of Oppi's built-ins. */
  readonly skipped: readonly PluginIssue[];
  readonly errors: readonly PluginIssue[];
}

export interface PluginHostOptions {
  /** The built-in root: one package whose `chord.plugins` lists the built-ins in order. */
  readonly builtInDir: string;
  /** Pi's agent directory: `<agentDir>/plugins/` and its enabled packages are the owner's plugins. */
  readonly agentDir: string;
  /** Names of the built-in plugins the server cannot run without. */
  readonly required: ReadonlySet<string>;
  /** The server's own extensions: `first` before the built-ins, `afterBuiltIns` after them. */
  readonly core: {
    readonly first: readonly Extension[];
    readonly afterBuiltIns: readonly Extension[];
  };
}

/** What Oppi knows of the classic extensions saved Agents select by ID. */
export interface ClassicPluginIndex {
  /** IDs of classic extensions whose plugin is one of Oppi's built-ins, so every session has it. */
  readonly bundled: ReadonlySet<string>;
  /** A readable name per ID. */
  readonly names: ReadonlyMap<string, string>;
}

/** The core facet's plugin name; a plugin of this name is refused. */
const CORE_PLUGIN = "@oppi/core";

type Entry = { readonly loaded: LoadedPlugin; readonly facet: Facet<chordNext.Principal> };
type Candidate = Entry & { readonly fresh: boolean };
type Found = DiscoveredPlugin & {
  readonly source: PluginSource;
  readonly extensionIds: readonly string[];
};

export class PluginHost {
  private host?: Host;
  /** Installed plugins in install order: built-ins, then owner plugins. */
  private entries: Entry[] = [];
  /** The plugins the last load or reload failed, by name. */
  private failed: PluginFailure[] = [];
  /** What the core facet's `compose` orders by: the plugin set Chord is committing or holds. */
  private composition: Composition = { order: new Map(), builtIns: new Set() };
  private classicIndex: ClassicPluginIndex = { bundled: new Set(), names: new Map() };
  private sync: Promise<unknown> = Promise.resolve();
  private reader?: RegistryReader;
  /** The host's own extensions outside plugins: per-session MCP. */
  private readonly overlay: Registry = createRegistry();
  private readonly coreNames: ReadonlySet<string>;
  private readonly coreTools: ReadonlySet<string>;

  constructor(private readonly options: PluginHostOptions) {
    const core = [...options.core.first, ...options.core.afterBuiltIns];
    this.coreNames = new Set(core.map((extension) => extension.name));
    this.coreTools = new Set(
      core.flatMap((extension) => (extension.tools ?? []).map((t) => t.name)),
    );
  }

  /** Installed plugins in install order: built-ins first. */
  get plugins(): readonly LoadedPlugin[] {
    return this.entries.map((entry) => entry.loaded);
  }

  get classic(): ClassicPluginIndex {
    return this.classicIndex;
  }

  /**
   * Every plugin: the installed ones in install order (built-ins first), each with why its last
   * load failed if it did, then those that failed and have no code installed. `enabled` says
   * whether sessions select an installed extension, by its name.
   */
  listings(enabled: (extension: string) => boolean): PluginListing[] {
    const failures = new Map(this.failed.map((failure) => [failure.name, failure]));
    const listings: PluginListing[] = this.plugins.map((plugin) => {
      const failure = failures.get(plugin.name);
      failures.delete(plugin.name);
      return {
        name: plugin.name,
        extension: plugin.extension.name,
        source: plugin.source,
        dir: plugin.dir,
        facet: plugin.facet,
        extensionIds: plugin.extensionIds,
        required: plugin.required,
        enabled: enabled(plugin.extension.name),
        runtimes: plugin.runtimes,
        ...contributionsOf(plugin.extension),
        ...(failure ? { loadError: failure.message } : {}),
        kept: failure !== undefined,
      };
    });
    for (const failure of failures.values())
      listings.push({
        name: failure.name,
        source: failure.source,
        dir: failure.dir,
        facet: failure.facet,
        extensionIds: failure.extensionIds,
        required: failure.required,
        enabled: false,
        runtimes: [],
        ...contributionsOf(undefined),
        loadError: failure.message,
        kept: false,
      });
    return listings;
  }

  /**
   * The first load. Throws when a required built-in fails (or the built-in root has a problem):
   * the server does not run without them. Any other plugin that fails is reported and left out.
   */
  load(): Promise<PluginReport> {
    if (this.host) throw new Error("Plugins are loaded already");
    return this.serialize(() => this.syncOnce(true));
  }

  /**
   * Discover and load every plugin again. A plugin loaded before has its code replaced in place:
   * running tool calls finish on the old code, the next request, task step, or call uses the new.
   * A plugin whose new code fails keeps its old code; a plugin that is gone is uninstalled, except
   * a required built-in, which keeps its code.
   */
  reload(): Promise<PluginReport> {
    if (!this.host) throw new Error("Plugins are not loaded");
    return this.serialize(() => this.syncOnce(false));
  }

  /** The registry the Harness reads: the composed plugins, then the overlay's extensions. */
  registry(): RegistryReader {
    if (!this.reader) throw new Error("Plugins are not loaded");
    return this.reader;
  }

  /** Install a host-owned extension outside plugins (a session's MCP), replacing one of its name. */
  install(extension: Extension): void {
    this.overlay.install(extension);
  }

  uninstall(extension: Extension): void {
    this.overlay.uninstall(extension);
  }

  async close(): Promise<void> {
    await this.host?.close(BACKGROUND_CONTEXT);
  }

  private serialize<T>(run: () => Promise<T>): Promise<T> {
    const next = this.sync.then(run);
    this.sync = next.catch(() => undefined);
    return next;
  }

  /** Composes the table: the core's `first`, built-ins, the core's `afterBuiltIns`, owner plugins. */
  private readonly core = defineFacet((host) => {
    host.serve(Extensions, {
      compose: (table, { report }) => this.compose(table, report),
    });
  });

  private compose(
    table: RegistryTable<Extension>,
    report: (conflict: { message: string; plugins: string[] }) => void,
  ): RegistrySnapshot {
    const registry = createRegistry();
    const names = new Set<string>();
    const install = (extension: Extension, plugin?: string): void => {
      // pi-durable replaces an extension of an installed name silently; the pre-check refused
      // that for facets, so this is a contribution from a plugin's object.
      if (names.has(extension.name)) {
        report({
          message: `Extension "${extension.name}" is installed already`,
          plugins: [plugin ?? ""],
        });
        return;
      }
      try {
        registry.install(extension);
        names.add(extension.name);
      } catch (error) {
        report({ message: safeErrorMessage(error), plugins: [plugin ?? ""] });
      }
    };
    for (const extension of this.options.core.first) install(extension);
    const { order, builtIns } = this.composition;
    const sorted = [...table].sort(
      (a, b) => (order.get(a.plugin) ?? Infinity) - (order.get(b.plugin) ?? Infinity),
    );
    const builtIn = (plugin: string): boolean => builtIns.has(plugin);
    for (const { plugin, value } of sorted) if (builtIn(plugin)) install(value, plugin);
    for (const extension of this.options.core.afterBuiltIns) install(extension);
    for (const { plugin, value } of sorted) if (!builtIn(plugin)) install(value, plugin);
    return registry.snapshot();
  }

  private async syncOnce(first: boolean): Promise<PluginReport> {
    const previous = new Map(this.entries.map((entry) => [entry.loaded.name, entry]));
    const errors: PluginIssue[] = [];
    const skipped: PluginIssue[] = [];

    // Discovery. A root that cannot be read changes nothing of its plugins.
    let builtIns: Found[] | undefined;
    try {
      const found = await discoverPackage(this.options.builtInDir);
      errors.push(...found.problems.map(issueOf));
      builtIns = found.plugins.map((plugin) => ({
        ...plugin,
        source: "built-in",
        extensionIds: [],
      }));
    } catch (error) {
      errors.push({
        path: this.options.builtInDir,
        message: `Discovery failed: ${safeErrorMessage(error)}`,
      });
    }
    if (first && (!builtIns || errors.length > 0)) throw fatal(errors);
    const builtInNames = new Set([
      ...(builtIns ?? []).map((plugin) => plugin.name),
      ...this.plugins.filter((plugin) => plugin.source === "built-in").map((plugin) => plugin.name),
    ]);
    let owners: Found[] | undefined;
    try {
      const found = await discoverOwnerPlugins(this.options.agentDir);
      errors.push(...found.problems.map(issueOf));
      const bundled = new Set<string>();
      owners = [];
      for (const plugin of found.plugins) {
        if (plugin.name === CORE_PLUGIN) {
          errors.push({
            path: plugin.dir,
            plugin: plugin.name,
            message: `"${CORE_PLUGIN}" is reserved`,
          });
        } else if (builtInNames.has(plugin.name)) {
          skipped.push({
            path: plugin.dir,
            plugin: plugin.name,
            message: `"${plugin.name}" is built into Oppi`,
          });
          for (const id of plugin.extensionIds) bundled.add(id);
        } else owners.push(plugin);
      }
      this.classicIndex = { bundled, names: found.names };
    } catch (error) {
      errors.push({
        path: this.options.agentDir,
        message: `Package discovery failed: ${safeErrorMessage(error)}`,
      });
    }

    // Evaluation. A plugin whose new code fails keeps its previous code, if any.
    const candidates: Candidate[] = [];
    const seen = new Set<string>();
    for (const found of [...(builtIns ?? []), ...(owners ?? [])]) {
      if (!found.facet) continue;
      seen.add(found.name);
      const old = previous.get(found.name);
      try {
        const facet = await evaluateFacet(found.facet);
        const { extension, runtimes } = contributionOf(facet);
        candidates.push({
          fresh: true,
          facet,
          loaded: {
            name: found.name,
            source: found.source,
            dir: found.dir,
            facet: found.facet,
            required: found.source === "built-in" && this.options.required.has(found.name),
            extension,
            runtimes,
            extensionIds: found.extensionIds,
          },
        });
      } catch (error) {
        errors.push({ path: found.facet, plugin: found.name, message: safeErrorMessage(error) });
        if (old) candidates.push({ ...old, fresh: false });
      }
    }
    // Plugins not found again: a required built-in, any plugin of a root that could not be read,
    // and a plugin whose folder has a problem now (a broken package.json: still on disk) keep their
    // code; the others are uninstalled.
    const problemPaths = errors.map((issue) => issue.path);
    for (const old of previous.values()) {
      if (seen.has(old.loaded.name)) continue;
      const unread =
        (old.loaded.source === "built-in" ? !builtIns : !owners) ||
        problemPaths.some((path) => path === old.loaded.dir || isInside(path, old.loaded.dir));
      if (unread || old.loaded.required) {
        if (!unread)
          errors.push({
            path: old.loaded.dir,
            plugin: old.loaded.name,
            message: "The required built-in plugin is missing",
          });
        candidates.push({ ...old, fresh: false });
      }
    }

    // The pre-check: built-ins first, then plugins loaded before, then new ones, in found order.
    const rank = (candidate: Candidate): number =>
      candidate.loaded.source === "built-in" ? 0 : previous.has(candidate.loaded.name) ? 1 : 2;
    const ordered = candidates
      .map((candidate, index) => ({ candidate, index }))
      .sort((a, b) => rank(a.candidate) - rank(b.candidate) || a.index - b.index)
      .map(({ candidate }) => candidate);
    const taken = this.takenByCore();
    const accepted: Candidate[] = [];
    for (const candidate of ordered) {
      let chosen: Candidate | undefined = candidate;
      const clash = this.clashOf(candidate.loaded, taken);
      if (clash) {
        errors.push({
          path: candidate.loaded.facet,
          plugin: candidate.loaded.name,
          message: clash,
        });
        const old = previous.get(candidate.loaded.name);
        chosen =
          candidate.fresh && old && !this.clashOf(old.loaded, taken)
            ? { ...old, fresh: false }
            : undefined;
      }
      if (!chosen) continue;
      accepted.push(chosen);
      take(taken, chosen.loaded);
    }
    if (first) {
      const missing = [...this.options.required].filter(
        (name) => !accepted.some((candidate) => candidate.fresh && candidate.loaded.name === name),
      );
      if (missing.length > 0)
        throw fatal([
          ...errors,
          ...missing.map((name) => ({
            path: this.options.builtInDir,
            plugin: name,
            message: "The required built-in plugin did not load",
          })),
        ]);
    }

    // Commit on the Chord host: one batch replaces every changed plugin's contribution.
    const facets: PluginFacet<chordNext.Principal>[] = [
      { name: CORE_PLUGIN, facet: this.core },
      ...accepted.map((entry) => ({ name: entry.loaded.name, facet: entry.facet })),
    ];
    // `compose` runs inside Chord's commit, so it orders by the set being committed; the plugin
    // list itself changes only once Chord took it, and a load or reload that rejects (before its
    // commit) leaves both as they were.
    this.composition = compositionOf(arranged(accepted));
    let result = accepted;
    try {
      if (!this.host) {
        const host = createHost({ onError: reportHostError });
        const report = await host.load(facets, BACKGROUND_CONTEXT);
        this.host = host;
        if (report.failed.length > 0) {
          const failed = new Set(report.failed.map((failure) => failure.plugin));
          for (const failure of report.failed)
            errors.push({
              path: this.options.builtInDir,
              plugin: failure.plugin,
              message: safeErrorMessage(failure.error),
            });
          if ([...failed].some((name) => this.options.required.has(name))) throw fatal(errors);
          result = accepted.filter((entry) => !failed.has(entry.loaded.name));
        }
        const value = await host.registry(Extensions, BACKGROUND_CONTEXT);
        this.reader = withOverlay(registryReader(value, BACKGROUND_CONTEXT), this.overlay);
      } else {
        const failed = accepted
          .filter((entry) => !entry.fresh)
          .map((entry) => ({
            plugin: entry.loaded.name,
            error: new Error("Its new code failed to load"),
          }));
        const report = await this.host.reload(facets, BACKGROUND_CONTEXT, { failed });
        // Chord kept the old code of a plugin whose setup failed in its staging.
        const known = new Set(failed.map((failure) => failure.plugin));
        const chordFailed = report.failed.filter((failure) => !known.has(failure.plugin));
        if (chordFailed.length > 0) {
          result = accepted.flatMap((entry) => {
            if (!chordFailed.some((failure) => failure.plugin === entry.loaded.name))
              return [entry];
            const old = previous.get(entry.loaded.name);
            return old ? [{ ...old, fresh: false }] : [];
          });
          for (const failure of chordFailed)
            errors.push({
              path: this.options.builtInDir,
              plugin: failure.plugin,
              message: safeErrorMessage(failure.error),
            });
        }
      }
    } catch (error) {
      this.composition = compositionOf(this.entries);
      throw error;
    }
    this.entries = arranged(result);
    this.composition = compositionOf(this.entries);
    this.failed = this.failuresOf(errors, [...(builtIns ?? []), ...(owners ?? [])], previous);

    const names = new Set(result.map((entry) => entry.loaded.extension.name));
    const pluginReport: PluginReport = {
      loaded: result.filter((entry) => entry.fresh).map((entry) => entry.loaded),
      kept: result.filter((entry) => !entry.fresh).map((entry) => entry.loaded),
      removed: [...previous.values()]
        .map((old) => old.loaded.extension.name)
        .filter((name) => !names.has(name)),
      skipped,
      errors,
    };
    logReport(pluginReport);
    return pluginReport;
  }

  /**
   * The plugins `errors` name, each with every message of its own. A folder's problem names no
   * plugin: it belongs to the plugins installed from that folder that it hid this time, which keep
   * their code.
   */
  private failuresOf(
    errors: readonly PluginIssue[],
    found: readonly Found[],
    previous: ReadonlyMap<string, Entry>,
  ): PluginFailure[] {
    type Known = Pick<PluginFailure, "name" | "source" | "dir" | "facet" | "extensionIds">;
    const failures = new Map<string, { known: Known; messages: string[] }>();
    const add = (known: Known, message: string): void => {
      const failure = failures.get(known.name) ?? { known, messages: [] };
      failure.messages.push(message);
      failures.set(known.name, failure);
    };
    for (const issue of errors) {
      if (issue.plugin !== undefined) {
        const known =
          found.find((plugin) => plugin.name === issue.plugin) ??
          previous.get(issue.plugin)?.loaded;
        if (known) add(known, issue.message);
        continue;
      }
      for (const old of previous.values())
        if (
          !found.some((plugin) => plugin.name === old.loaded.name) &&
          (issue.path === old.loaded.dir || isInside(issue.path, old.loaded.dir))
        )
          add(old.loaded, issue.message);
    }
    return [...failures.values()].map(({ known, messages }) => ({
      name: known.name,
      source: known.source,
      dir: known.dir,
      facet: known.facet,
      required: known.source === "built-in" && this.options.required.has(known.name),
      extensionIds: known.extensionIds,
      message: messages.join("; "),
    }));
  }

  private takenByCore(): Taken {
    const taken: Taken = { names: new Map(), tools: new Map(), tasks: new Map() };
    for (const name of this.coreNames) taken.names.set(name, "Oppi");
    for (const task of createRegistry().snapshot().tasks())
      taken.tasks.set(task.definition.name, "pi-durable");
    for (const extension of [...this.options.core.first, ...this.options.core.afterBuiltIns])
      for (const task of extension.tasks ?? []) taken.tasks.set(task.definition.name, "Oppi");
    return taken;
  }

  /**
   * Why `plugin`'s extension cannot be installed next to `taken`; undefined when it can. Checks
   * what pi-durable's `install` would throw on, and what it would allow but Oppi refuses: a name or
   * tool another plugin has.
   */
  private clashOf(plugin: LoadedPlugin, taken: Taken): string | undefined {
    const { extension } = plugin;
    const holder = taken.names.get(extension.name);
    if (holder) return `Extension "${extension.name}" is taken by ${holder}`;
    const tools = new Set<string>();
    for (const tool of extension.tools ?? []) {
      if (tools.has(tool.name))
        return `Extension "${extension.name}" has two tools named "${tool.name}"`;
      tools.add(tool.name);
      const by = taken.tools.get(tool.name);
      if (by) return `Tool "${tool.name}" is taken by ${by}`;
      if (plugin.source === "owner" && this.coreTools.has(tool.name))
        return `Tool "${tool.name}" is built into Oppi`;
    }
    const sections = new Set<string>();
    for (const { key } of extension.sections ?? []) {
      if (typeof key !== "string" || !SECTION_KEY.test(key))
        return `Section key ${JSON.stringify(key)} must match ${SECTION_KEY}`;
      if (key === INSTRUCTIONS_KEY)
        return `Section key "${key}" is reserved for the agent's instructions`;
      if (sections.has(key))
        return `Extension "${extension.name}" has two sections with key "${key}"`;
      sections.add(key);
    }
    const tasks = new Set<string>();
    for (const task of extension.tasks ?? []) {
      const name = task.definition.name;
      if (tasks.has(name)) return `Extension "${extension.name}" has two tasks named "${name}"`;
      tasks.add(name);
      const by = taken.tasks.get(name);
      if (by) return `Task "${name}" is taken by ${by}`;
    }
    return undefined;
  }
}

/** pi-durable's rule for a section key (`registry.ts`), and the key it keeps for instructions. */
const SECTION_KEY = /^[a-z][a-z0-9_-]*$/;
const INSTRUCTIONS_KEY = "instructions";

/** Extension names, tool names and task names, each with who holds it. */
type Taken = {
  names: Map<string, string>;
  tools: Map<string, string>;
  tasks: Map<string, string>;
};

function take(taken: Taken, plugin: LoadedPlugin): void {
  const holder = `plugin "${plugin.name}"`;
  taken.names.set(plugin.extension.name, holder);
  for (const tool of plugin.extension.tools ?? []) taken.tools.set(tool.name, holder);
  for (const task of plugin.extension.tasks ?? []) taken.tasks.set(task.definition.name, holder);
}

/** `list` in install order, built-ins first. */
function arranged(list: readonly Entry[]): Entry[] {
  return [
    ...list.filter((entry) => entry.loaded.source === "built-in"),
    ...list.filter((entry) => entry.loaded.source === "owner"),
  ].map(({ loaded, facet }) => ({ loaded, facet }));
}

/** What `compose` orders by: each plugin's place, and which are built-ins. */
function compositionOf(entries: readonly Entry[]): Composition {
  return {
    order: new Map(entries.map((entry, index) => [entry.loaded.name, index])),
    builtIns: new Set(
      entries.filter((entry) => entry.loaded.source === "built-in").map((e) => e.loaded.name),
    ),
  };
}

type Composition = {
  readonly order: ReadonlyMap<string, number>;
  readonly builtIns: ReadonlySet<string>;
};

/** Whether `dir` lies inside `path`. */
function isInside(path: string, dir: string): boolean {
  const rest = relative(path, dir);
  return rest !== "" && !rest.startsWith("..") && !isAbsolute(rest);
}

function issueOf(problem: DiscoveryProblem): PluginIssue {
  return { path: problem.path, message: problem.error };
}

function fatal(errors: readonly PluginIssue[]): Error {
  return new Error(
    `Oppi's built-in plugins failed to load: ${errors
      .map((issue) => `${issue.plugin ? `${issue.plugin} ` : ""}(${issue.path}): ${issue.message}`)
      .join("; ")}`,
  );
}

function reportHostError(error: HostError): void {
  if (error.kind === "registry_conflict")
    log.warn("plugins.conflict", { message: error.message, plugins: error.plugins.join(",") });
  else log.error("plugins.host_error", { kind: error.kind });
}

function logReport(report: PluginReport): void {
  if (report.loaded.length || report.removed.length)
    log.info("plugins.loaded", {
      loaded: report.loaded.map((plugin) => plugin.name),
      removed: [...report.removed],
    });
  for (const issue of report.errors)
    log.error("plugins.load_failed", {
      path: issue.path,
      ...(issue.plugin ? { plugin: issue.plugin } : {}),
      message: issue.message,
    });
}

/** `base` with `overlay`'s extensions after its own; a snapshot is rebuilt only when either changed. */
function withOverlay(base: RegistryReader, overlay: Registry): RegistryReader {
  let cache:
    { base: RegistrySnapshot; overlay: RegistrySnapshot; merged: RegistrySnapshot } | undefined;
  return {
    snapshot() {
      const b = base.snapshot();
      const o = overlay.snapshot();
      if (cache?.base === b && cache.overlay === o) return cache.merged;
      let merged = b;
      if (o.installed().length > 0) {
        const registry = createRegistry();
        for (const extension of b.installed()) registry.install(extension);
        for (const extension of o.installed()) registry.install(extension);
        merged = registry.snapshot();
      }
      cache = { base: b, overlay: o, merged };
      return merged;
    },
    subscribe(listener) {
      const fromBase = base.subscribe(listener);
      const fromOverlay = overlay.subscribe(listener);
      return () => {
        fromBase();
        fromOverlay();
      };
    },
  };
}

// ---------------------------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------------------------

/**
 * The modules plugin code shares with the server, one instance each (upstream's host packages):
 * a second pi-durable would make a plugin's documents and tasks unknown to the Harness.
 */
const HOST_MODULES: Record<string, unknown> = {
  "oppi/v1": oppiV1,
  "oppi/v1/schema": oppiV1Schema,
  "@earendil-works/pi-durable": piDurable,
  "@earendil-works/pi-durable/env": piDurableEnv,
  "@earendil-works/pi-durable/env/node": piDurableEnvNode,
  "@earendil-works/pi-durable/tools": piDurableTools,
  "@earendil-works/chord": chord,
  "@earendil-works/chord/context": chordContext,
  "@earendil-works/chord/delta": chordDelta,
  "@earendil-works/chord/next": chordNext,
  "@earendil-works/pi-ai": piAi,
  "@earendil-works/pi-schema": piSchema,
};

/**
 * Import a facet with a fresh jiti (no module cache, so a reload re-reads the facet and every file
 * it imports) and check its default export is a facet.
 */
async function evaluateFacet(file: string): Promise<Facet<chordNext.Principal>> {
  const jiti = createJiti(import.meta.url, {
    moduleCache: false,
    tryNative: false,
    virtualModules: HOST_MODULES,
  });
  const facet: unknown = await jiti.import(file, { default: true });
  if (
    typeof facet !== "object" ||
    facet === null ||
    typeof (facet as Facet<chordNext.Principal>).setup !== "function"
  )
    throw new Error("The default export must be a facet (defineFacet from oppi/v1)");
  return facet as Facet<chordNext.Principal>;
}

/**
 * The extension a facet contributes to `Extensions`, from running its setup against a recorder
 * (Chord runs it again when it loads the plugin; a setup only declares). Throws when the setup
 * throws or contributes no valid extension.
 */
function contributionOf(facet: Facet<chordNext.Principal>): {
  extension: Extension;
  runtimes: readonly PluginRuntime[];
} {
  let contributed: unknown;
  const host: FacetHost = {
    serve: () => undefined,
    references: () => ({
      value: [],
      watch: () => Promise.reject(new Error("Not available while recording")),
    }),
  };
  const self: FacetSelf = {
    contribute: (registry, value) => {
      if (registry.name === Extensions.name) contributed = value;
    },
  };
  facet.setup(host, self);
  if (contributed === undefined)
    throw new Error("The facet contributes no extension to Extensions");
  const problem = notAnExtension(contributed);
  if (problem)
    throw new Error(`Its contribution is not a durable extension (defineExtension): ${problem}`);
  const extension = contributed as Extension & { runtimes?: unknown };
  return { extension, runtimes: pluginRuntimes(extension.runtimes) };
}

function notAnExtension(value: unknown): string | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return "not an object";
  const record = value as Record<string, unknown>;
  if (typeof record.name !== "string" || !record.name.trim()) return "it has no name";
  for (const key of ["tools", "sections", "hooks", "wraps", "tasks"] as const)
    if (record[key] !== undefined && !Array.isArray(record[key]))
      return `its \`${key}\` is not an array`;
  return undefined;
}

// ---------------------------------------------------------------------------------------------
// The owner's plugins
// ---------------------------------------------------------------------------------------------

/**
 * The owner's plugins: `<agentDir>/plugins/`, then the plugins of each enabled user-scope Pi
 * package, resolved exactly as Pi resolves classic extensions (`<agentDir>/extensions`, packages
 * from settings, the same enable and disable settings). A plugin found in a Pi package carries the
 * IDs of that package's classic extensions.
 */
async function discoverOwnerPlugins(agentDir: string): Promise<{
  plugins: Found[];
  problems: DiscoveryProblem[];
  /** A readable name per classic extension ID Pi resolved, plugin or not. */
  names: Map<string, string>;
}> {
  const root = await discoverRoot(join(agentDir, "plugins"));
  const problems = [...root.problems];
  const plugins: Found[] = root.plugins.map((plugin) => ({
    ...plugin,
    source: "owner",
    extensionIds: [],
  }));
  const settingsManager = SettingsManager.create(homedir(), agentDir, { projectTrusted: false });
  const resolved = await new DefaultPackageManager({
    cwd: homedir(),
    agentDir,
    settingsManager,
  }).resolve(async () => "skip");
  for (const entry of settingsManager.drainErrors())
    problems.push({
      path: agentDir,
      error: `Pi settings (${entry.scope}): ${entry.error.message}`,
    });
  const names = new Map<string, string>();
  const packages = new Map<string, string[]>();
  for (const resource of resolved.extensions) {
    const id = serverResourceId("extension", resource.path);
    const packageDir = piPackageRoot(resource.path, resource.metadata);
    names.set(id, basename(packageDir ?? resource.path).replace(/\.[cm]?[jt]s$/, ""));
    if (!resource.enabled || !packageDir) continue;
    const ids = packages.get(packageDir) ?? [];
    if (!ids.includes(id)) ids.push(id);
    packages.set(packageDir, ids);
  }
  for (const [packageDir, extensionIds] of packages) {
    let found: Awaited<ReturnType<typeof discoverPiPackage>>;
    try {
      found = await discoverPiPackage(packageDir);
    } catch (error) {
      problems.push({ path: packageDir, error: safeErrorMessage(error) });
      continue;
    }
    problems.push(...found.problems);
    for (const plugin of found.plugins) {
      const other = plugins.find((known) => known.name === plugin.name);
      if (!other) plugins.push({ ...plugin, source: "owner", extensionIds });
      else if (other.dir === plugin.dir) {
        // One plugin linked twice (the plugin root and a Pi package): one plugin, both IDs.
        plugins[plugins.indexOf(other)] = {
          ...other,
          extensionIds: [...new Set([...other.extensionIds, ...extensionIds])],
        };
      } else
        problems.push({
          path: plugin.dir,
          error: `plugin "${plugin.name}" is in ${other.dir} already`,
        });
    }
  }
  return { plugins, problems, names };
}
