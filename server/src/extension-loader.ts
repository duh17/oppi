/**
 * Workspace extension resolution.
 *
 * Resolves named extensions from pi host extension locations for workspace-related flows.
 */

import { existsSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, extname, join, resolve } from "node:path";

import {
  DefaultPackageManager,
  SettingsManager,
  type ResolvedResource,
} from "@earendil-works/pi-coding-agent";

import { isManagedExtensionName } from "../extensions/built-ins.js";
import { createLogger } from "./logger.js";

const DEFAULT_AGENT_DIR = join(homedir(), ".pi", "agent");
const HOST_EXTENSIONS_DIR = join(DEFAULT_AGENT_DIR, "extensions");

const log = createLogger({ base: { component: "extension_loader" } });

const EXTENSION_NAME_RE = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/;

export interface ResolvedExtension {
  /** Normalized extension name (without file extension). */
  name: string;
  /** Absolute host path to extension entry (file or directory). */
  path: string;
  /** Entry kind for installation behavior. */
  kind: "file" | "directory";
}

export interface ResolveWorkspaceExtensionsResult {
  extensions: ResolvedExtension[];
  warnings: string[];
}

export interface HostExtensionInfo {
  /** Extension name (without .ts/.js suffix). */
  name: string;
  /** Absolute host path to entry. */
  path: string;
  /** Entry kind for loading behavior. */
  kind: "file" | "directory";
}

export interface ListHostExtensionsOptions {
  /**
   * Workspace cwd/hostMount used to discover project-local `.pi/extensions`.
   * When omitted, only global host extensions are returned.
   */
  cwd?: string;
  /** Override global directory for tests. */
  globalDir?: string;
}

export interface ListConfiguredHostExtensionsOptions {
  /**
   * Workspace cwd/hostMount used to resolve project-local settings/packages.
   * When omitted, only user/global scope is considered.
   */
  cwd?: string;
  /** Override pi agent dir for tests. */
  agentDir?: string;
}

/** Validate extension name accepted by workspace API. */
export function isValidExtensionName(name: string): boolean {
  return EXTENSION_NAME_RE.test(name.trim());
}

/**
 * Normalize a loadable extension entry path to the extension name Pi uses.
 *
 * Pi treats `extensions/foo/index.ts` as extension `foo`, while a real top-level
 * `extensions/index.ts` stays `index`.
 */
export function extensionNameFromPath(path: string): string {
  const fileName = basename(path);
  const suffix = extname(fileName);
  const baseName = suffix ? fileName.slice(0, -suffix.length) : fileName;

  if (baseName !== "index") {
    return baseName;
  }

  const parentDir = dirname(path);
  if (basename(dirname(parentDir)) === "extensions") {
    return basename(parentDir);
  }

  return baseName;
}

type ExtensionResourceMetadata = Partial<ResolvedResource["metadata"]>;

function sanitizeExtensionNameCandidate(value: string): string | undefined {
  const sanitized = value
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^[._-]+/, "")
    .replace(/[._-]+$/, "");

  return isValidExtensionName(sanitized) ? sanitized : undefined;
}

function packageScopedName(scope: string | undefined, packageName: string): string | undefined {
  const concisePackageName = packageName.startsWith("pi-")
    ? packageName.slice("pi-".length)
    : packageName;
  return sanitizeExtensionNameCandidate(
    scope ? `${scope}-${concisePackageName}` : concisePackageName,
  );
}

export function extensionNameFromPackageSource(source: string | undefined): string | undefined {
  if (!source?.startsWith("npm:")) {
    return undefined;
  }

  const spec = source.slice("npm:".length).trim();
  if (!spec) {
    return undefined;
  }

  if (spec.startsWith("@")) {
    const slash = spec.indexOf("/");
    if (slash <= 1) {
      return undefined;
    }

    const scope = spec.slice(1, slash);
    const packageWithVersion = spec.slice(slash + 1);
    const versionAt = packageWithVersion.lastIndexOf("@");
    const packageName = versionAt > 0 ? packageWithVersion.slice(0, versionAt) : packageWithVersion;
    return packageScopedName(scope, packageName);
  }

  const versionAt = spec.lastIndexOf("@");
  const packageName = versionAt > 0 ? spec.slice(0, versionAt) : spec;
  return packageScopedName(undefined, packageName);
}

function extensionNameFromNodeModulesPath(path: string): string | undefined {
  const parts = path.split(/[\\/]+/);
  const nodeModulesIndex = parts.lastIndexOf("node_modules");
  if (nodeModulesIndex < 0) {
    return undefined;
  }

  const first = parts[nodeModulesIndex + 1];
  if (!first) {
    return undefined;
  }

  if (first.startsWith("@")) {
    const packageName = parts[nodeModulesIndex + 2];
    return packageName ? packageScopedName(first.slice(1), packageName) : undefined;
  }

  return packageScopedName(undefined, first);
}

export function extensionNameForAllowlist(
  path: string,
  metadata?: ExtensionResourceMetadata,
): string {
  const pathName = extensionNameFromPath(path);
  if (pathName !== "index") {
    return pathName;
  }

  return (
    extensionNameFromPackageSource(metadata?.origin === "package" ? metadata.source : undefined) ??
    extensionNameFromNodeModulesPath(path) ??
    pathName
  );
}

/**
 * List host extensions available for workspace selection.
 *
 * Scans the global host directory (`~/.pi/agent/extensions`) and, when `cwd`
 * is provided, the project-local directory (`<cwd>/.pi/extensions`). Oppi
 * entries with invalid extension names are excluded.
 *
 * The result is deduplicated by extension name. Project-local entries win over
 * global ones because pi loads local extensions first.
 */
export function listHostExtensions(options: ListHostExtensionsOptions = {}): HostExtensionInfo[] {
  const byName = new Map<string, HostExtensionInfo>();
  const dirs = [
    getProjectExtensionsDir(options.cwd),
    options.globalDir ?? HOST_EXTENSIONS_DIR,
  ].filter((dir): dir is string => Boolean(dir));

  for (const dir of dirs) {
    for (const extension of discoverExtensionsInDir(dir)) {
      const existing = byName.get(extension.name);
      if (!existing) {
        byName.set(extension.name, extension);
        continue;
      }

      // Prefer directory entries over files when both exist in the same scope.
      if (existing.kind === "file" && extension.kind === "directory") {
        byName.set(extension.name, extension);
      }
    }
  }

  return Array.from(byName.values()).sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * List host extensions using pi's package/settings resolver.
 *
 * This includes:
 * - auto-discovered global/project extension directories
 * - settings-declared local extension paths
 * - package-provided extensions from `pi install` (git/npm/local package sources)
 *
 * Falls back to directory scanning if package resolution fails.
 */
export async function listConfiguredHostExtensions(
  options: ListConfiguredHostExtensionsOptions = {},
): Promise<HostExtensionInfo[]> {
  const cwd = resolveWorkspaceCwd(options.cwd, homedir()) ?? homedir();
  const agentDir = options.agentDir ?? DEFAULT_AGENT_DIR;

  try {
    const settingsManager = SettingsManager.create(cwd, agentDir);
    const packageManager = new DefaultPackageManager({
      cwd,
      agentDir,
      settingsManager,
    });

    // Do not auto-install missing packages from the server route.
    const resolved = await packageManager.resolve(async () => "skip");

    // Keep the package/settings resolver as the source of truth when it sees an
    // extension, but also merge a direct directory scan. The resolver can miss
    // auto-discovered directory extensions (`extensions/name/index.ts`) in some
    // server contexts, while native pi still loads them. Workspace editing needs
    // to show those immediately so they can be enabled for the next session.
    return mergeHostExtensions(
      listFromResolvedResources(resolved.extensions),
      listHostExtensions({ cwd: options.cwd, globalDir: join(agentDir, "extensions") }),
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    log.warn("extensions.configured_resolution.failed", { error: message });

    return listHostExtensions({
      cwd: options.cwd,
      globalDir: join(agentDir, "extensions"),
    });
  }
}

/**
 * Resolve workspace extension paths for spawn/install.
 *
 * Resolves named extensions from the workspace's `extensions` list.
 */
export function resolveWorkspaceExtensions(
  extensionNames: string[] | undefined,
): ResolveWorkspaceExtensionsResult {
  const warnings: string[] = [];
  const resolved: ResolvedExtension[] = [];
  const seen = new Set<string>();

  for (const raw of extensionNames ?? []) {
    const requested = raw.trim();
    if (requested.length === 0) {
      continue;
    }

    if (!isValidExtensionName(requested)) {
      warnings.push(`Ignoring invalid extension name: ${requested}`);
      continue;
    }

    const normalized = normalizeName(requested);
    const ext = resolveByName(normalized);
    if (!ext) {
      warnings.push(`Extension not found: ${requested}`);
      continue;
    }

    if (seen.has(ext.path)) {
      continue;
    }

    seen.add(ext.path);
    resolved.push(ext);
  }

  return { extensions: resolved, warnings };
}

/** Compute destination filename/directory under agent/extensions/. */
export function extensionInstallName(extension: ResolvedExtension): string {
  if (extension.kind === "directory") {
    return extension.name;
  }

  const suffix = extname(extension.path);
  if (suffix.length > 0) {
    return `${extension.name}${suffix}`;
  }

  return extension.name;
}

function mergeHostExtensions(
  primary: HostExtensionInfo[],
  secondary: HostExtensionInfo[],
): HostExtensionInfo[] {
  const byName = new Map<string, HostExtensionInfo>();

  for (const extension of [...primary, ...secondary]) {
    if (!byName.has(extension.name)) {
      byName.set(extension.name, extension);
    }
  }

  return Array.from(byName.values()).sort((a, b) => a.name.localeCompare(b.name));
}

function listFromResolvedResources(resources: ResolvedResource[]): HostExtensionInfo[] {
  // DefaultPackageManager.resolve() already returns resources in pi precedence order.
  // Keep first name collision to mirror native pi behavior.
  const byName = new Map<string, HostExtensionInfo>();

  for (const resource of resources) {
    if (!resource.enabled) {
      continue;
    }

    const extension = toHostExtensionInfo(resource.path, resource.metadata);
    if (!extension) {
      continue;
    }

    if (byName.has(extension.name)) {
      continue;
    }

    byName.set(extension.name, extension);
  }

  return Array.from(byName.values()).sort((a, b) => a.name.localeCompare(b.name));
}

function toHostExtensionInfo(
  absPath: string,
  metadata?: ExtensionResourceMetadata,
): HostExtensionInfo | null {
  const kind = detectKind(absPath);
  if (!kind) {
    return null;
  }

  const fileName = basename(absPath);
  const suffix = extname(fileName);
  const name = extensionNameForAllowlist(absPath, metadata);
  if (kind === "file") {
    if (suffix !== ".ts" && suffix !== ".js") {
      return null;
    }

    // Skip test files — they are not loadable extensions.
    if (name.endsWith(".test") || name.endsWith(".spec")) {
      return null;
    }
  }

  if (!isValidExtensionName(name) || isManagedExtensionName(name)) {
    return null;
  }

  return {
    name,
    path: absPath,
    kind,
  };
}

function discoverExtensionsInDir(dir: string): HostExtensionInfo[] {
  if (!existsSync(dir)) {
    return [];
  }

  const byName = new Map<string, HostExtensionInfo>();

  for (const entry of readdirSync(dir)) {
    if (entry.startsWith(".")) {
      continue;
    }

    const absPath = join(dir, entry);
    const extension = toHostExtensionInfo(absPath);
    if (!extension) {
      continue;
    }

    const existing = byName.get(extension.name);
    if (!existing || (existing.kind === "file" && extension.kind === "directory")) {
      byName.set(extension.name, extension);
    }
  }

  return Array.from(byName.values());
}

function getProjectExtensionsDir(cwd: string | undefined): string | null {
  const resolvedCwd = resolveWorkspaceCwd(cwd);
  if (!resolvedCwd) {
    return null;
  }

  return join(resolvedCwd, ".pi", "extensions");
}

function resolveWorkspaceCwd(cwd: string | undefined, fallback?: string): string | null {
  const raw = cwd?.trim();
  if (!raw) {
    return fallback ?? null;
  }

  const expanded = raw === "~" || raw.startsWith("~/") ? raw.replace(/^~(?=\/|$)/, homedir()) : raw;
  return resolve(expanded);
}

function resolveByName(name: string): ResolvedExtension | null {
  const normalized = normalizeName(name);
  const candidates = uniqueCandidates([
    join(HOST_EXTENSIONS_DIR, name),
    join(HOST_EXTENSIONS_DIR, normalized),
    join(HOST_EXTENSIONS_DIR, `${normalized}.ts`),
    join(HOST_EXTENSIONS_DIR, `${normalized}.js`),
  ]);

  for (const candidate of candidates) {
    const kind = detectKind(candidate);
    if (kind) {
      return {
        name: normalized,
        path: candidate,
        kind,
      };
    }
  }

  return null;
}

function normalizeName(name: string): string {
  if (name.endsWith(".ts") || name.endsWith(".js")) {
    return name.slice(0, -3);
  }
  return name;
}

function uniqueCandidates(candidates: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];

  for (const candidate of candidates) {
    if (seen.has(candidate)) continue;
    seen.add(candidate);
    out.push(candidate);
  }

  return out;
}

function detectKind(absPath: string): "file" | "directory" | null {
  if (!existsSync(absPath)) return null;

  try {
    const stat = statSync(absPath);
    if (stat.isDirectory()) return "directory";
    if (stat.isFile()) return "file";
    return null;
  } catch {
    // Test environments may mock existsSync without statSync.
    const suffix = extname(absPath);
    if (suffix === ".ts" || suffix === ".js") {
      return "file";
    }
    return "directory";
  }
}
