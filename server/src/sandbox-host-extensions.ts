import { readFile } from "node:fs/promises";
import { isAbsolute, join, relative, sep } from "node:path";

import {
  DefaultPackageManager,
  type ResolvedResource,
  type SettingsManager,
} from "@earendil-works/pi-coding-agent";

import { shouldShadowSandboxWorkspacePath } from "./gondolin-manager.js";
import { BUILTIN_EXTENSION_PATH_PREFIX, type McpBuiltinName } from "./host-mcp-extensions.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import { pluginRuntimes, type PluginRuntime } from "./plugin-runtimes.js";
import { piPackageRoot } from "./plugin-discovery.js";
import { canonicalServerResourcePath, serverResourceId } from "./server-resource-id.js";

const log = createLogger({ base: { component: "sandbox_host_extensions" } });

type PiAutoDiscovery = { cwd: string; addAutoDiscoveredResources: (...args: unknown[]) => void };

/**
 * Keep a Pi package manager from walking a workspace's `.agents/skills` on the host: a
 * sandbox's, or one that resolves only extensions, which that walk never adds. On every resolve
 * it walks `.agents/skills` from its cwd up to the git root
 * (`addAutoDiscoveredResources`, synchronously, with no cycle guard), so two `loop -> .` links
 * block the server. That walk is the method's only use of `cwd`, so it runs from `/`, which no
 * guest can write; project `.pi` resources keep the workspace's base dir. Throws if Pi no longer
 * has this shape, rather than walk silently.
 */
export function keepAutoDiscoveryOffHost(packageManager: unknown): void {
  const manager = packageManager as Partial<PiAutoDiscovery> | undefined;
  const discover = manager?.addAutoDiscoveredResources;
  if (typeof discover !== "function" || typeof manager?.cwd !== "string")
    throw new Error("Cannot keep sandbox Skill discovery off the host with this Pi version");
  const shaped = manager as PiAutoDiscovery;
  shaped.addAutoDiscoveredResources = (...args) => {
    const cwd = shaped.cwd;
    shaped.cwd = "/";
    try {
      discover.apply(shaped, args);
    } finally {
      shaped.cwd = cwd;
    }
  };
}

/**
 * Whether the sandbox guest can write `path`: its real path is in the workspace mount
 * (`mountRoot`, canonical) and not hidden by the mount's shadow, as `.pi` is.
 */
function guestWritable(path: string, mountRoot: string): boolean {
  const inside = relative(mountRoot, canonicalServerResourcePath(path));
  if (inside.startsWith("..") || isAbsolute(inside)) return false;
  return !shouldShadowSandboxWorkspacePath({
    op: "write",
    path: `/${inside.split(sep).join("/")}`,
  });
}

/** Scopes whose extensions a sandbox may load: the owner's and the workspace's `.pi`. */
const SANDBOX_EXTENSION_SCOPES = new Set(["user", "project"]);

/**
 * The runtimes a classic Pi extension declares it is safe in: its Pi package's
 * `package.json` `"oppi": { "classicRuntimes": [...] }`, read like a durable extension's
 * `runtimes`. Absent means `["host"]`. A package adds `"sandbox"` only when its classic tools
 * act on nothing of the host (no host commands, files, or network), such as a tool that only
 * asks the user. A single-file extension has no package, so it is host-only. So is one whose
 * package or entry the guest can write (`guestWritable`): the guest could add the declaration
 * and its own code.
 */
async function classicRuntimes(
  resource: ResolvedResource,
  mountRoot: string,
): Promise<readonly PluginRuntime[]> {
  const root = piPackageRoot(resource.path, resource.metadata);
  if (!root || guestWritable(root, mountRoot) || guestWritable(resource.path, mountRoot))
    return ["host"];
  let manifest: unknown;
  try {
    manifest = JSON.parse(await readFile(join(root, "package.json"), "utf8"));
  } catch {
    return ["host"];
  }
  const declared = (manifest as { oppi?: { classicRuntimes?: unknown } } | null)?.oppi
    ?.classicRuntimes;
  try {
    return pluginRuntimes(declared);
  } catch (error) {
    log.warn("sandbox_extensions.bad_classic_runtimes", {
      path: root,
      error: safeErrorMessage(error),
    });
    return ["host"];
  }
}

export interface SandboxExtensions {
  /** What the session's resource loader loads, as `additionalExtensionPaths` with `noExtensions`. */
  readonly paths: string[];
  /** Canonical paths of the loaded extensions whose tools run on the host. */
  readonly hostSide: ReadonlySet<string>;
  /** `hostExtensions` IDs that name no enabled extension. */
  readonly unavailable: string[];
}

/**
 * The extensions a classic sandbox session loads. Their code runs in the server process, so a
 * tool of theirs reaches the host past the VM and Allowed Hosts. Without an opt-in the session
 * loads only the MCP built-ins and enabled extensions whose package declares the `sandbox`
 * runtime (`classicRuntimes`). A saved Agent's exact selection (`selectedPaths`) is the opt-in
 * for its extensions; otherwise the workspace's `sandboxConfig.hostExtensions` IDs are, for
 * enabled extensions. Every opted-in extension that does not declare `sandbox` is host-side.
 */
export async function resolveSandboxExtensions(input: {
  cwd: string;
  agentDir: string;
  settingsManager: SettingsManager;
  selectedPaths: readonly string[] | undefined;
  hostExtensionIds: readonly string[];
  builtinNames: readonly McpBuiltinName[];
}): Promise<SandboxExtensions> {
  const packageManager = new DefaultPackageManager({
    cwd: input.cwd,
    agentDir: input.agentDir,
    settingsManager: input.settingsManager,
  });
  keepAutoDiscoveryOffHost(packageManager);
  const resolved = (await packageManager.resolve(async () => "skip")).extensions.filter(
    (resource) =>
      SANDBOX_EXTENSION_SCOPES.has(resource.metadata.scope) &&
      !resource.path.startsWith(BUILTIN_EXTENSION_PATH_PREFIX),
  );
  const hostSide = new Set<string>();
  const mountRoot = canonicalServerResourcePath(input.cwd);
  const sandboxSafe = async (resource: ResolvedResource): Promise<boolean> =>
    (await classicRuntimes(resource, mountRoot)).includes("sandbox");

  if (input.selectedPaths !== undefined) {
    const byPath = new Map(
      resolved.map((resource) => [canonicalServerResourcePath(resource.path), resource]),
    );
    for (const path of input.selectedPaths) {
      if (path.startsWith(BUILTIN_EXTENSION_PATH_PREFIX)) continue;
      const canonical = canonicalServerResourcePath(path);
      const resource = byPath.get(canonical);
      if (!resource || !(await sandboxSafe(resource))) hostSide.add(canonical);
    }
    return { paths: [...input.selectedPaths], hostSide, unavailable: [] };
  }

  const optedIn = new Set(input.hostExtensionIds);
  const found = new Set<string>();
  const paths = input.builtinNames.map((name) => `${BUILTIN_EXTENSION_PATH_PREFIX}${name}`);
  for (const resource of resolved) {
    if (!resource.enabled) continue;
    const id = serverResourceId("extension", resource.path);
    const safe = await sandboxSafe(resource);
    if (optedIn.has(id)) {
      found.add(id);
      if (!safe) hostSide.add(canonicalServerResourcePath(resource.path));
    } else if (!safe) continue;
    paths.push(resource.path);
  }
  return { paths, hostSide, unavailable: [...optedIn].filter((id) => !found.has(id)) };
}
