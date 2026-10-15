import { DefaultPackageManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import type { Extension } from "@earendil-works/pi-durable";
import { createJiti } from "jiti";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { extname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import type { DurableExtensionModule, DurableExtensionRuntime } from "./durable-extension-api.js";
import { serverResourceId } from "./server-resource-id.js";

/** A Pi package that has a durable entry next to (or instead of) its classic one. */
export interface DurableExtensionPackage {
  /** Package directory. */
  readonly root: string;
  /** The `durable.ts` (or `package.json` `oppi.durable`) file, resolved through symlinks. */
  readonly entry: string;
  /** Server resource IDs of the package's classic extensions, as saved Agents select them. */
  readonly extensionIds: readonly string[];
}

export interface LoadedDurableExtension {
  readonly extension: Extension;
  readonly runtimes: readonly DurableExtensionRuntime[];
  readonly entry: string;
  /** The classic extension IDs this durable extension stands for in a saved Agent's selection. */
  readonly extensionIds: readonly string[];
}

export interface DurableExtensionIssue {
  readonly entry: string;
  readonly message: string;
}

export interface DurableExtensionLoadResult {
  readonly loaded: LoadedDurableExtension[];
  /** Not loaded on purpose, such as a package Oppi already bundles. */
  readonly skipped: DurableExtensionIssue[];
  readonly errors: DurableExtensionIssue[];
}

/** Names and tool names a loaded extension must not take. */
export interface DurableExtensionReserved {
  readonly names: ReadonlySet<string>;
  readonly tools: ReadonlySet<string>;
}

const DURABLE_ENTRY_FILES = ["durable.ts", "durable.js"] as const;
const RUNTIMES: readonly DurableExtensionRuntime[] = ["host", "sandbox"];

/**
 * Find durable entries among the enabled user-scope Pi packages, resolved exactly as Pi
 * resolves classic extensions (`~/.pi/agent/extensions`, packages from settings, the same
 * enable and disable settings). Project-scope packages are not read: they need the per-
 * workspace trust decision, and the registry is shared by every session.
 *
 * A package's durable entry is `package.json` `oppi.durable`, else `durable.ts` or
 * `durable.js` in the package directory. A single-file extension has no package directory
 * and so no durable entry.
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
  const packages: Array<{ root: string; entry: string; extensionIds: string[] }> = [];
  for (const resource of resolved.extensions) {
    if (!resource.enabled) continue;
    const root = packageRoot(resource.path, resource.metadata);
    if (!root) continue;
    let entry: string | undefined;
    try {
      entry = durableEntry(root);
    } catch (error) {
      errors.push({ entry: join(root, "package.json"), message: messageOf(error) });
      continue;
    }
    if (!entry) continue;
    // The real path, so a symlinked package's relative imports resolve where its files are.
    const real = realpathSync(entry);
    const id = serverResourceId("extension", resource.path);
    const known = packages.find((candidate) => candidate.entry === real);
    if (known) {
      if (!known.extensionIds.includes(id)) known.extensionIds.push(id);
      continue;
    }
    packages.push({ root, entry: real, extensionIds: [id] });
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

function durableEntry(root: string): string | undefined {
  const manifestPath = join(root, "package.json");
  if (existsSync(manifestPath)) {
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as {
      oppi?: { durable?: unknown };
    };
    const declared = manifest.oppi?.durable;
    if (declared !== undefined) {
      if (typeof declared !== "string" || !declared.trim())
        throw new Error("`oppi.durable` must be a relative path to the durable entry");
      const entry = resolve(root, declared);
      if (!existsSync(entry))
        throw new Error(`\`oppi.durable\` points to a missing file: ${entry}`);
      return entry;
    }
  }
  return DURABLE_ENTRY_FILES.map((name) => join(root, name)).find((file) => existsSync(file));
}

/**
 * Import each package's durable entry with a fresh jiti instance (no module cache, so a
 * reload re-reads the entry and every file it imports) and validate its default export.
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
  for (const { entry, extensionIds } of packages) {
    let module: unknown;
    try {
      module = await jiti.import(entry, { default: true });
    } catch (error) {
      errors.push({ entry, message: `Import failed: ${messageOf(error)}` });
      continue;
    }
    const checked = checkModule(module);
    if (typeof checked === "string") {
      errors.push({ entry, message: checked });
      continue;
    }
    const { extension, runtimes } = checked;
    if (reserved.names.has(extension.name)) {
      skipped.push({ entry, message: `"${extension.name}" is built into Oppi` });
      continue;
    }
    if (names.has(extension.name)) {
      errors.push({ entry, message: `Another package already loaded "${extension.name}"` });
      continue;
    }
    const clash = (extension.tools ?? []).find(
      (tool) => reserved.tools.has(tool.name) || tools.has(tool.name),
    );
    if (clash) {
      errors.push({
        entry,
        message: `Tool "${clash.name}" is already offered by another extension`,
      });
      continue;
    }
    names.add(extension.name);
    for (const tool of extension.tools ?? []) tools.add(tool.name);
    loaded.push({ extension, runtimes, entry, extensionIds });
  }
  return { loaded, skipped, errors };
}

function checkModule(
  value: unknown,
): { extension: Extension; runtimes: readonly DurableExtensionRuntime[] } | string {
  if (!isRecord(value) || !isRecord(value.extension))
    return "The default export must be `defineDurableExtension({ extension, runtimes? })`";
  const module = value as unknown as DurableExtensionModule;
  const { extension } = module;
  if (typeof extension.name !== "string" || !extension.name.trim())
    return "The extension has no name";
  for (const key of ["tools", "sections", "hooks", "wraps", "tasks"] as const)
    if (extension[key] !== undefined && !Array.isArray(extension[key]))
      return `The extension's \`${key}\` must be an array`;
  const runtimes = module.runtimes ?? ["host"];
  if (
    !Array.isArray(runtimes) ||
    runtimes.length === 0 ||
    runtimes.some((runtime) => !RUNTIMES.includes(runtime))
  )
    return '`runtimes` must list "host", "sandbox", or both';
  return { extension, runtimes: [...new Set(runtimes)] };
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
