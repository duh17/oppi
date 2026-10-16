import { DefaultPackageManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import type { Extension } from "@earendil-works/pi-durable";
import { createJiti } from "jiti";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { extname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { serverResourceId } from "./server-resource-id.js";

/** Execution runtimes a durable extension may load in. */
export type DurableExtensionRuntime = "host" | "sandbox";

/**
 * `package.json` `oppi.durable`: where a package's durable entry is and which runtimes may select
 * it. The key stays under `oppi` until upstream names a plugin manifest; then only the key changes.
 */
export interface DurableExtensionManifest {
  /** The entry file, resolved inside the package. */
  readonly entry: string;
  /**
   * Runtimes whose sessions may select it. Default `["host"]`. Code always runs in the server
   * process; only list `"sandbox"` when every command and file access goes through `api.env`.
   */
  readonly runtimes: readonly DurableExtensionRuntime[];
}

/** A package whose `package.json` declares a durable entry. */
export interface DurableExtensionPackage extends DurableExtensionManifest {
  /** Package directory. */
  readonly root: string;
  /** Server resource IDs of the package's classic extensions, as saved Agents select them. */
  readonly extensionIds: readonly string[];
}

export interface LoadedDurableExtension {
  readonly extension: Extension;
  readonly runtimes: readonly DurableExtensionRuntime[];
  readonly root: string;
  readonly entry: string;
  /** The classic extension IDs this durable extension stands for in a saved Agent's selection. */
  readonly extensionIds: readonly string[];
}

export interface DurableExtensionIssue {
  /** The file that failed: the manifest or the entry. */
  readonly entry: string;
  readonly message: string;
  /** The package it belongs to; unset for a problem outside any package (Pi settings). */
  readonly root?: string;
}

export interface DurableExtensionLoadResult {
  readonly loaded: LoadedDurableExtension[];
  /** Not loaded on purpose, such as a package Oppi already bundles. */
  readonly skipped: DurableExtensionIssue[];
  readonly errors: DurableExtensionIssue[];
}

/** Names, tool names, and task names a loaded extension must not take. */
export interface DurableExtensionReserved {
  readonly names: ReadonlySet<string>;
  readonly tools: ReadonlySet<string>;
  /**
   * Task names the registry already holds, each with the extension that holds it (undefined for
   * pi-durable's own tasks). Only the extension of that name may bring the task again.
   */
  readonly tasks: ReadonlyMap<string, string | undefined>;
}

/** A `package.json` whose `oppi.durable` manifest is missing where required, or invalid. */
export class DurableManifestError extends Error {
  override readonly name = "DurableManifestError";
  constructor(
    readonly manifest: string,
    message: string,
  ) {
    super(message);
  }
}

const RUNTIMES: readonly DurableExtensionRuntime[] = ["host", "sandbox"];
const MANIFEST_KEYS = new Set(["entry", "runtimes"]);

/**
 * Read `package.json` `oppi.durable` in `root`. Undefined when the package declares no durable
 * entry; throws `DurableManifestError` when the manifest is unreadable or invalid.
 *
 * ```json
 * "oppi": { "durable": { "entry": "./src/durable.ts", "runtimes": ["host", "sandbox"] } }
 * ```
 *
 * A `.js` entry whose file is missing names its `.ts` source, as relative imports do in
 * TypeScript: a package that ships both its source and its build declares the `.js` path.
 */
export function readDurableManifest(root: string): DurableExtensionManifest | undefined {
  const path = join(root, "package.json");
  if (!existsSync(path)) return undefined;
  let json: unknown;
  try {
    json = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new DurableManifestError(path, `package.json is not valid JSON: ${messageOf(error)}`);
  }
  if (!isRecord(json) || json.oppi === undefined) return undefined;
  if (!isRecord(json.oppi)) throw new DurableManifestError(path, "`oppi` must be an object");
  const declared = json.oppi.durable;
  if (declared === undefined) return undefined;
  if (!isRecord(declared) || Array.isArray(declared))
    throw new DurableManifestError(
      path,
      '`oppi.durable` must be an object: { "entry": "./durable.ts", "runtimes": ["host"] }',
    );
  const unknown = Object.keys(declared).filter((key) => !MANIFEST_KEYS.has(key));
  if (unknown.length > 0)
    throw new DurableManifestError(
      path,
      `\`oppi.durable\` has unknown keys: ${unknown.join(", ")} (allowed: entry, runtimes)`,
    );
  const { entry, runtimes = ["host"] } = declared;
  if (typeof entry !== "string" || !entry.startsWith("./"))
    throw new DurableManifestError(
      path,
      '`oppi.durable.entry` must be a path inside the package starting with "./"',
    );
  const file = resolve(root, entry);
  const inside = relative(root, file);
  if (!inside || inside.startsWith("..") || isAbsolute(inside))
    throw new DurableManifestError(
      path,
      "`oppi.durable.entry` must name a file inside the package",
    );
  if (
    !Array.isArray(runtimes) ||
    runtimes.length === 0 ||
    runtimes.some((runtime) => !RUNTIMES.includes(runtime as DurableExtensionRuntime)) ||
    new Set(runtimes).size !== runtimes.length
  )
    throw new DurableManifestError(
      path,
      '`oppi.durable.runtimes` must list "host", "sandbox", or both, once each',
    );
  const source = file.endsWith(".js") ? `${file.slice(0, -3)}.ts` : undefined;
  const found = existsSync(file) ? file : source && existsSync(source) ? source : undefined;
  if (!found)
    throw new DurableManifestError(
      path,
      `\`oppi.durable.entry\` points to a missing file: ${file}`,
    );
  return { entry: found, runtimes: runtimes as DurableExtensionRuntime[] };
}

/**
 * Find durable entries among the enabled user-scope Pi packages, resolved exactly as Pi
 * resolves classic extensions (`~/.pi/agent/extensions`, packages from settings, the same
 * enable and disable settings). Project-scope packages are not read: they need the per-
 * workspace trust decision, and the registry is shared by every session.
 *
 * A package's durable entry is the one its `package.json` declares in `oppi.durable`; a package
 * without one, or a single-file extension, has none.
 */
export async function discoverDurableExtensionPackages(agentDir: string): Promise<{
  packages: DurableExtensionPackage[];
  errors: DurableExtensionIssue[];
}> {
  const settingsManager = SettingsManager.create(homedir(), agentDir, { projectTrusted: false });
  const resolved = await new DefaultPackageManager({
    cwd: homedir(),
    agentDir,
    settingsManager,
  }).resolve(async () => "skip");
  const errors: DurableExtensionIssue[] = settingsManager.drainErrors().map((entry) => ({
    entry: agentDir,
    message: `Pi settings (${entry.scope}): ${entry.error.message}`,
  }));
  const packages: Array<DurableExtensionPackage & { extensionIds: string[] }> = [];
  const failed = new Set<string>();
  for (const resource of resolved.extensions) {
    if (!resource.enabled) continue;
    const root = packageRoot(resource.path, resource.metadata);
    if (!root || failed.has(root)) continue;
    let manifest: DurableExtensionManifest | undefined;
    try {
      manifest = readDurableManifest(root);
    } catch (error) {
      failed.add(root);
      errors.push({ root, entry: join(root, "package.json"), message: messageOf(error) });
      continue;
    }
    if (!manifest) continue;
    // The real path, so a symlinked package's relative imports resolve where its files are.
    const entry = realpathSync(manifest.entry);
    const id = serverResourceId("extension", resource.path);
    const known = packages.find((candidate) => candidate.entry === entry);
    if (known) {
      if (!known.extensionIds.includes(id)) known.extensionIds.push(id);
      continue;
    }
    packages.push({ root, entry, runtimes: manifest.runtimes, extensionIds: [id] });
  }
  return { packages, errors };
}

/**
 * Oppi's own durable packages, in install order. Each is a directory under `extensions/durable`
 * (next to `src/`, also in the build) whose `package.json` declares its entry like any package.
 */
const BUNDLED_PACKAGES = [
  "sandbox-tools",
  "ask",
  "working-words",
  "background-jobs",
  "sessions",
  "project-context",
  "control",
] as const;

/** `extensions/durable` of this server: the source tree in development, the build when built. */
export const BUNDLED_PACKAGES_DIR = fileURLToPath(
  new URL("../extensions/durable/", import.meta.url),
);

/**
 * Oppi's bundled durable packages in `dir`. Each must declare its entry: a bundled package
 * without an `oppi.durable` manifest is an error, not a classic-only package.
 */
export function bundledDurableExtensionPackages(dir: string = BUNDLED_PACKAGES_DIR): {
  packages: DurableExtensionPackage[];
  errors: DurableExtensionIssue[];
} {
  const packages: DurableExtensionPackage[] = [];
  const errors: DurableExtensionIssue[] = [];
  for (const name of BUNDLED_PACKAGES) {
    const root = join(dir, name);
    try {
      const manifest = readDurableManifest(root);
      if (!manifest)
        throw new DurableManifestError(
          join(root, "package.json"),
          `Bundled package ${name} has no \`oppi.durable\` manifest`,
        );
      packages.push({
        root,
        entry: realpathSync(manifest.entry),
        runtimes: manifest.runtimes,
        extensionIds: [],
      });
    } catch (error) {
      errors.push({ root, entry: join(root, "package.json"), message: messageOf(error) });
    }
  }
  return { packages, errors };
}

function packageRoot(
  path: string,
  metadata: { packageRoot?: string; baseDir?: string } | undefined,
): string | undefined {
  if (metadata?.packageRoot) return metadata.packageRoot;
  if (!metadata?.baseDir) return undefined;
  // A top-level extension directory: `<agentDir>/extensions/<name>/…/index.ts`.
  const extensionsDir = join(metadata.baseDir, "extensions");
  const inside = relative(extensionsDir, path);
  if (!inside || inside.startsWith("..") || isAbsolute(inside)) return undefined;
  const [first, ...rest] = inside.split(sep);
  return first && rest.length > 0 ? join(extensionsDir, first) : undefined;
}

/**
 * Import each package's durable entry with a fresh jiti instance (no module cache, so a
 * reload re-reads the entry and every file it imports) and validate its default export: a
 * pi-durable `Extension`, or an array of them, each selectable in the manifest's runtimes.
 * One broken package fails alone.
 */
export async function loadDurableExtensions(
  packages: readonly DurableExtensionPackage[],
  reserved: DurableExtensionReserved,
): Promise<DurableExtensionLoadResult> {
  const jiti = createJiti(import.meta.url, {
    moduleCache: false,
    tryNative: false,
    alias: hostModuleAliases(),
  });
  const loaded: LoadedDurableExtension[] = [];
  const skipped: DurableExtensionIssue[] = [];
  const errors: DurableExtensionIssue[] = [];
  const names = new Set<string>();
  const tools = new Set<string>();
  const tasks = new Set<string>();
  for (const { root, entry, runtimes, extensionIds } of packages) {
    let module: unknown;
    try {
      module = await jiti.import(entry, { default: true });
    } catch (error) {
      errors.push({ root, entry, message: `Import failed: ${messageOf(error)}` });
      continue;
    }
    // The export is package code: a getter that throws fails this package, not the load.
    let extensions: Extension[] | string;
    let problem: string | undefined;
    try {
      extensions = extensionsOf(module);
      if (typeof extensions === "string") {
        errors.push({ root, entry, message: extensions });
        continue;
      }
      // A package loads whole or not at all, so a reload never keeps half of its old code.
      problem = extensions
        .map((extension) => clashOf(extension, reserved, { names, tools, tasks }))
        .find((issue) => issue !== undefined);
    } catch (error) {
      errors.push({ root, entry, message: `Invalid extension: ${messageOf(error)}` });
      continue;
    }
    if (problem) {
      const builtIn = extensions.every((extension) => reserved.names.has(extension.name));
      (builtIn ? skipped : errors).push({ root, entry, message: problem });
      continue;
    }
    for (const extension of extensions) {
      names.add(extension.name);
      for (const tool of extension.tools ?? []) tools.add(tool.name);
      for (const task of extension.tasks ?? []) tasks.add(task.definition.name);
      loaded.push({ extension, runtimes, root, entry, extensionIds });
    }
  }
  return { loaded, skipped, errors };
}

/** pi-durable's rule for a section key (`registry.ts`), and the key it keeps for instructions. */
const SECTION_KEY = /^[a-z][a-z0-9_-]*$/;
const INSTRUCTIONS_KEY = "instructions";

/**
 * Why `extension` cannot be installed next to the registry (`reserved`) and the extensions
 * already taken from this load (`taken`); undefined when it can. Checks what pi-durable's
 * `registry.install` would throw on, so a bad package is a load error instead of a throw.
 */
function clashOf(
  extension: Extension,
  reserved: DurableExtensionReserved,
  taken: { names: ReadonlySet<string>; tools: ReadonlySet<string>; tasks: ReadonlySet<string> },
): string | undefined {
  if (reserved.names.has(extension.name)) return `"${extension.name}" is built into Oppi`;
  if (taken.names.has(extension.name)) return `Another package already loaded "${extension.name}"`;
  const tools = new Set<string>();
  for (const tool of extension.tools ?? []) {
    if (reserved.tools.has(tool.name) || taken.tools.has(tool.name))
      return `Tool "${tool.name}" is already offered by another extension`;
    if (tools.has(tool.name))
      return `Extension "${extension.name}" has two tools named "${tool.name}"`;
    tools.add(tool.name);
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
    const holder = reserved.tasks.get(name);
    if ((reserved.tasks.has(name) && holder !== extension.name) || taken.tasks.has(name))
      return `Task "${name}" is already installed${holder ? ` by "${holder}"` : ""}`;
    if (tasks.has(name)) return `Extension "${extension.name}" has two tasks named "${name}"`;
    tasks.add(name);
  }
  return undefined;
}

/** The extensions of a default export, or why it is not one. */
function extensionsOf(value: unknown): Extension[] | string {
  const list = Array.isArray(value) ? value : [value];
  if (list.length === 0) return "The default export is an empty array of extensions";
  const names = new Set<string>();
  for (const candidate of list) {
    const problem = notAnExtension(candidate);
    if (problem)
      return `The default export must be a pi-durable Extension (defineExtension) or an array of them: ${problem}`;
    const { name } = candidate as Extension;
    if (names.has(name)) return `The default export has two extensions named "${name}"`;
    names.add(name);
  }
  return list as Extension[];
}

function notAnExtension(value: unknown): string | undefined {
  if (!isRecord(value) || Array.isArray(value)) return "not an object";
  if (typeof value.name !== "string" || !value.name.trim()) return "it has no name";
  for (const key of ["tools", "sections", "hooks", "wraps", "tasks"] as const)
    if (value[key] !== undefined && !Array.isArray(value[key]))
      return `its \`${key}\` is not an array`;
  return undefined;
}

let aliases: Record<string, string> | undefined;

/**
 * One copy of each module the Harness shares with extension code. A second copy of
 * pi-durable would make the extension's documents and tasks unknown to the Harness.
 */
function hostModuleAliases(): Record<string, string> {
  if (aliases) return aliases;
  const file = (specifier: string): string => fileURLToPath(import.meta.resolve(specifier));
  // This module's own extension: `.js` when built, `.ts` when run from source in tests.
  const api = fileURLToPath(
    new URL(`./durable-extension-api${extname(fileURLToPath(import.meta.url))}`, import.meta.url),
  );
  aliases = {
    "oppi/durable": api,
    ...Object.fromEntries(
      [
        "@earendil-works/pi-durable",
        "@earendil-works/pi-durable/env",
        "@earendil-works/pi-durable/env/node",
        "@earendil-works/pi-durable/tools",
        "@earendil-works/chord",
        "@earendil-works/chord/context",
        "@earendil-works/chord/delta",
        "@earendil-works/pi-ai",
        "typebox",
        "typebox/compile",
        "typebox/value",
      ].map((specifier) => [specifier, file(specifier)]),
    ),
  };
  return aliases;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
