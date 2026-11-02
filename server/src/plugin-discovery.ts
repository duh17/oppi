import type { Dirent } from "node:fs";
import { readdir, readFile, realpath, stat } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

/**
 * Plugin discovery in upstream Chord's documented layout (`packages/chord/docs/next/plugin-authoring.md`),
 * ported from Chord's `next-node/plugins/discover.ts`, which 1.5.0 ships but does not export. Replace it
 * with upstream's `discoverPlugins` once that is exported. Nothing here parses or runs plugin code.
 *
 * A package is a directory with a `package.json`: the plugins its `"chord": { "plugins": [...] }` lists
 * (paths, `*`/`**` globs, `!` exclusions); without that list itself when its top has a facet file, else
 * its subfolders with a `package.json`, else itself (contracts only). A root's top files named
 * `<name>.server.ts` are single-file plugins. Oppi's only host kind is `server`.
 *
 * Two departures from upstream: plugins keep their listing order instead of a name sort (the order of
 * Oppi's built-in root is its prompt sections' order), and a contracts-only plugin is returned with no
 * facet for the caller to leave out.
 */

/** Oppi's facet file names: the `server` kind only. */
const FACET_FILES = ["server.ts", "server.tsx", "server.js", "server.mjs"] as const;
const FACET_EXTENSIONS = [".ts", ".tsx", ".js", ".mjs"] as const;

/** An npm package name, scoped or not (Chord's `isPluginName`). */
const PLUGIN_NAME = /^(?:@[a-z0-9~-][a-z0-9._~-]*\/)?[a-z0-9~-][a-z0-9._~-]*$/;

/** A plugin on disk: its name (its `package.json` name, or a single file's), its real directory, its facet. */
export interface DiscoveredPlugin {
  readonly name: string;
  /** The directory's real path; a single-file plugin's is its root's. */
  readonly dir: string;
  /** The `server` facet file; undefined for a contracts-only plugin. */
  readonly facet: string | undefined;
}

/** A package, folder or file that is not a plugin, and why. */
export interface DiscoveryProblem {
  readonly path: string;
  readonly error: string;
}

export interface Discovery {
  readonly plugins: DiscoveredPlugin[];
  readonly problems: DiscoveryProblem[];
}

/**
 * The plugins of the root at `path`: each directory at its top is a package (`discoverPackage`), each
 * `<name>.server.ts` file a single-file plugin. A missing root is empty. A name found twice is reported
 * where it is found the second time; a single-file plugin loses to a directory plugin of its name.
 */
export async function discoverRoot(path: string): Promise<Discovery> {
  const entries = await entriesOf(path);
  if (!entries) return { plugins: [], problems: [] };
  const plugins: DiscoveredPlugin[] = [];
  const problems: DiscoveryProblem[] = [];
  for (const dir of entries.dirs) {
    const found = await discoverPackage(dir);
    plugins.push(...found.plugins);
    problems.push(...found.problems);
  }
  const root = await realpath(path);
  for (const file of entries.files) {
    const name = singleFileName(file);
    if (name === undefined) continue;
    const facet = join(root, file);
    if (!PLUGIN_NAME.test(name) || name.startsWith("@"))
      problems.push({ path: facet, error: `"${name}" is not a valid unscoped plugin name` });
    else plugins.push({ name, dir: root, facet });
  }
  return unique(plugins, problems);
}

/** The plugins of the package in `dir`, in its listing order, and its problems. */
export async function discoverPackage(dir: string): Promise<Discovery> {
  const real = await realpath(dir);
  const plugins: DiscoveredPlugin[] = [];
  const problems: DiscoveryProblem[] = [];
  for (const found of await packageAt(real))
    if ("error" in found) problems.push(found);
    else plugins.push(found);
  return unique(plugins, problems);
}

/**
 * Whether the Pi package of the classic extension at `path` holds a plugin with a server facet, so
 * enabling or disabling it changes what durable sessions load. A manifest problem counts as none.
 */
export async function packageHasPlugin(
  path: string,
  metadata: { packageRoot?: string; baseDir?: string } | undefined,
): Promise<boolean> {
  const root = piPackageRoot(path, metadata);
  if (!root) return false;
  try {
    return (await discoverPackage(root)).plugins.some((plugin) => plugin.facet !== undefined);
  } catch {
    return false;
  }
}

/**
 * The package directory of the classic extension Pi resolved at `path`: its package root, or for
 * a top-level extension directory `<agentDir>/extensions/<name>/…/index.ts`, that directory. A
 * single-file extension has none.
 */
export function piPackageRoot(
  path: string,
  metadata: { packageRoot?: string; baseDir?: string } | undefined,
): string | undefined {
  if (metadata?.packageRoot) return metadata.packageRoot;
  if (!metadata?.baseDir) return undefined;
  const extensionsDir = join(metadata.baseDir, "extensions");
  const inside = relative(extensionsDir, path);
  if (!inside || inside.startsWith("..") || isAbsolute(inside)) return undefined;
  const [first, ...rest] = inside.split(sep);
  return first && rest.length > 0 ? join(extensionsDir, first) : undefined;
}

type Found = DiscoveredPlugin | DiscoveryProblem;

/** `plugins` with every name once, the later ones reported. */
function unique(plugins: readonly DiscoveredPlugin[], problems: DiscoveryProblem[]): Discovery {
  const byName = new Map<string, DiscoveredPlugin>();
  for (const plugin of plugins) {
    const other = byName.get(plugin.name);
    if (other)
      problems.push({
        path: plugin.facet ?? plugin.dir,
        error: `plugin "${plugin.name}" is in ${other.dir} already`,
      });
    else byName.set(plugin.name, plugin);
  }
  return { plugins: [...byName.values()], problems };
}

/** The directories (by real path) and plain files directly under `path`, by name; undefined when missing. */
async function entriesOf(path: string): Promise<{ dirs: string[]; files: string[] } | undefined> {
  let names: string[];
  try {
    names = (await readdir(path)).sort();
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
  const dirs: string[] = [];
  const files: string[] = [];
  for (const name of names) {
    if (name.startsWith(".") || name === "node_modules") continue;
    const entry = join(path, name);
    // `stat` follows a symlink: a linked plugin directory is listed by its real path.
    const info = await stat(entry).catch(() => undefined);
    if (info?.isDirectory()) dirs.push(await realpath(entry));
    else if (info?.isFile()) files.push(name);
  }
  return { dirs, files };
}

type Manifest =
  | { readonly kind: "missing" }
  | { readonly kind: "invalid"; readonly error: string }
  | { readonly kind: "read"; readonly value: unknown };

async function manifestOf(dir: string): Promise<Manifest> {
  try {
    return { kind: "read", value: JSON.parse(await readFile(join(dir, "package.json"), "utf8")) };
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return { kind: "missing" };
    return { kind: "invalid", error: `package.json: ${(error as Error).message}` };
  }
}

async function packageAt(dir: string): Promise<Found[]> {
  const manifest = await manifestOf(dir);
  if (manifest.kind === "invalid") return [{ path: dir, error: manifest.error }];
  // A trust boundary: the package's own `package.json`.
  const value =
    manifest.kind === "read" ? (manifest.value as { chord?: { plugins?: unknown } }) : null;
  const listed = value?.chord?.plugins;
  if (listed !== undefined) return manifestPlugins(dir, listed);
  if (manifest.kind === "read" && (await facetOf(dir)).kind !== "none")
    return [await pluginAt(dir, manifest)];
  const inner: Found[] = [];
  for (const sub of (await entriesOf(dir))?.dirs ?? []) {
    const found = await manifestOf(sub);
    if (found.kind !== "missing") inner.push(await pluginAt(sub, found));
  }
  if (inner.length > 0) return inner;
  if (manifest.kind === "read") return [await pluginAt(dir, manifest)];
  return [{ path: dir, error: "no package.json" }];
}

/** The folders `chord.plugins` names, in its order (globs expand in name order). */
async function manifestPlugins(dir: string, listed: unknown): Promise<Found[]> {
  const problem = (error: string): Found[] => [
    { path: dir, error: `package.json: chord.plugins ${error}` },
  ];
  if (!Array.isArray(listed) || !listed.every((each) => typeof each === "string"))
    return problem("is not a list of plugin folders");
  const entries = listed as readonly string[];
  const excludes = entries
    .filter((each) => each.startsWith("!"))
    .map((each) => posix(each.slice(1)));
  const folders: string[] = [];
  for (const entry of entries.filter((each) => !each.startsWith("!"))) {
    const matched = /[*?]/.test(entry)
      ? await globFolders(dir, posix(entry))
      : [resolve(dir, entry)];
    for (const folder of matched) {
      const rest = relative(dir, folder);
      if (rest.startsWith("..") || isAbsolute(rest))
        return problem(`"${entry}" leaves the package`);
      const excluded = excludes.some((exclude) => matchesGlob(posix(rest) || ".", exclude));
      if (!excluded && !folders.includes(folder)) folders.push(folder);
    }
  }
  // One plugin inside another's directory would make the outer one's imports of it its own files.
  for (const inner of folders) {
    const outer = folders.find((folder) => insideDir(folder, inner));
    if (outer !== undefined) {
      const shown = (folder: string): string => posix(relative(dir, folder)) || ".";
      return problem(`lists "${shown(inner)}" inside the listed "${shown(outer)}"`);
    }
  }
  if (folders.length === 0) return problem("lists no plugin folder");
  const found: Found[] = [];
  for (const folder of folders) {
    const info = await stat(folder).catch(() => undefined);
    if (!info?.isDirectory()) {
      found.push({ path: folder, error: "listed in chord.plugins, not a directory" });
      continue;
    }
    const real = await realpath(folder);
    const rest = relative(dir, real);
    if (rest.startsWith("..") || isAbsolute(rest)) {
      found.push({ path: folder, error: "listed in chord.plugins, links out of the package" });
      continue;
    }
    found.push(await pluginAt(real, await manifestOf(real)));
  }
  return found;
}

async function pluginAt(dir: string, manifest: Manifest): Promise<Found> {
  if (manifest.kind === "missing") return { path: dir, error: "no package.json" };
  if (manifest.kind === "invalid") return { path: dir, error: manifest.error };
  const { name } = (manifest.value ?? {}) as { readonly name?: unknown };
  if (typeof name !== "string" || !PLUGIN_NAME.test(name))
    return { path: dir, error: `package.json: ${JSON.stringify(name)} is not a valid plugin name` };
  const facet = await facetOf(dir);
  if (facet.kind === "twice")
    return { path: dir, error: `two server facets: ${facet.files.join(", ")}` };
  return { name, dir, facet: facet.kind === "one" ? facet.file : undefined };
}

async function facetOf(
  dir: string,
): Promise<{ kind: "none" } | { kind: "one"; file: string } | { kind: "twice"; files: string[] }> {
  const files = new Set(await readdir(dir));
  const named = FACET_FILES.filter((file) => files.has(file));
  if (named.length > 1) return { kind: "twice", files: [...named] };
  const [file] = named;
  return file ? { kind: "one", file: join(dir, file) } : { kind: "none" };
}

/** The plugin name of a single-file plugin's file (`hello.server.ts`), or undefined for another file. */
function singleFileName(file: string): string | undefined {
  const extension = FACET_EXTENSIONS.find((each) => file.endsWith(each));
  if (extension === undefined) return undefined;
  const stem = file.slice(0, -extension.length);
  return stem.endsWith(".server") && stem.length > ".server".length
    ? stem.slice(0, -".server".length)
    : undefined;
}

function posix(path: string): string {
  return path.split(sep).join("/").replace(/^\.\//, "");
}

function insideDir(dir: string, path: string): boolean {
  const rest = relative(dir, path);
  return rest !== "" && !rest.startsWith("..") && !isAbsolute(rest);
}

/** `*` and `?` within one segment, `**` across segments; anything else literal. */
function matchesGlob(path: string, pattern: string): boolean {
  let source = "";
  for (let at = 0; at < pattern.length; at++) {
    const char = pattern.charAt(at);
    if (pattern.startsWith("**/", at)) {
      source += "(?:.*/)?";
      at += 2;
    } else if (pattern.startsWith("**", at)) {
      source += ".*";
      at += 1;
    } else if (char === "*") source += "[^/]*";
    else if (char === "?") source += "[^/]";
    else source += char.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  }
  return new RegExp(`^${source}$`).test(path);
}

/** How deep a glob of `chord.plugins` looks for folders. */
const GLOB_DEPTH = 6;

async function globFolders(dir: string, pattern: string): Promise<string[]> {
  const found: string[] = [];
  const walk = async (at: string, depth: number): Promise<void> => {
    if (depth > GLOB_DEPTH) return;
    let entries: Dirent[];
    try {
      entries = (await readdir(at, { withFileTypes: true })).sort((a, b) =>
        a.name < b.name ? -1 : a.name > b.name ? 1 : 0,
      );
    } catch {
      return;
    }
    for (const entry of entries) {
      if (!entry.isDirectory() || entry.name.startsWith(".") || entry.name === "node_modules")
        continue;
      const path = join(at, entry.name);
      if (matchesGlob(posix(relative(dir, path)), pattern)) found.push(path);
      await walk(path, depth + 1);
    }
  };
  await walk(dir, 1);
  return found;
}
