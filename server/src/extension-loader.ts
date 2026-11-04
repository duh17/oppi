/**
 * Workspace extension resolution.
 *
 * Lists the host extensions Pi resolves for a workspace, with enabled state.
 */

import { existsSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, extname, join, resolve } from "node:path";

import {
  DefaultPackageManager,
  SettingsManager,
  type ResolvedResource,
} from "@earendil-works/pi-coding-agent";

import { PiSettingsOperationError } from "./settings/pi-resource-errors.js";

const DEFAULT_AGENT_DIR = join(homedir(), ".pi", "agent");

const EXTENSION_NAME_RE = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/;

export interface HostExtensionInfo {
  /** Extension name (without .ts/.js suffix). */
  name: string;
  /** Absolute host path to entry. */
  path: string;
  /** Entry kind for loading behavior. */
  kind: "file" | "directory";
  /** Whether Pi will load this resource for the cwd/settings scope. */
  enabled?: boolean;
  /** Pi resource metadata used by settings editors. */
  metadata?: ExtensionResourceMetadata;
}

export interface ListConfiguredHostExtensionsOptions {
  /**
   * Workspace cwd/hostMount used to resolve project-local settings/packages.
   * When omitted, only user/global scope is considered.
   */
  cwd?: string;
  /** Override pi agent dir for tests. */
  agentDir?: string;
  /** False when Pi ignores the cwd's project resources. Default true. */
  projectTrusted?: boolean;
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
 * List host extension resources with enabled state from Pi resolution.
 *
 * Used by workspace settings. Matches Pi TUI / SDK session loading — no raw
 * directory-scan merge that invents non-extension folders, so helper/test
 * directories under `.pi/extensions` never appear as fake extensions.
 */
export async function listConfiguredHostExtensionResources(
  options: ListConfiguredHostExtensionsOptions = {},
): Promise<HostExtensionInfo[]> {
  const resolved = await resolveConfiguredHostExtensionResources(options);
  return listFromResolvedResources(resolved, { includeDisabled: true });
}

async function resolveConfiguredHostExtensionResources(
  options: ListConfiguredHostExtensionsOptions,
): Promise<ResolvedResource[]> {
  const cwd = resolveWorkspaceCwd(options.cwd, homedir()) ?? homedir();
  const agentDir = options.agentDir ?? DEFAULT_AGENT_DIR;

  const settingsManager = SettingsManager.create(cwd, agentDir, {
    projectTrusted: options.projectTrusted ?? true,
  });
  throwIfSettingsErrors(settingsManager, "load");
  const packageManager = new DefaultPackageManager({
    cwd,
    agentDir,
    settingsManager,
  });

  // Do not auto-install missing packages from the server route.
  const resolved = await packageManager.resolve(async () => "skip");
  throwIfSettingsErrors(settingsManager, "resolve");
  return resolved.extensions;
}

function throwIfSettingsErrors(settingsManager: SettingsManager, operation: string): void {
  const errors = settingsManager.drainErrors();
  if (errors.length === 0) return;
  const detail = errors
    .slice(0, 5)
    .map((entry) => `${entry.scope}: ${entry.error.message}`)
    .join("; ");
  throw new PiSettingsOperationError(operation, detail);
}

function listFromResolvedResources(
  resources: ResolvedResource[],
  options: { includeDisabled: boolean },
): HostExtensionInfo[] {
  // DefaultPackageManager.resolve() already returns resources in pi precedence order.
  // Keep first name collision to mirror native pi behavior.
  const byName = new Map<string, HostExtensionInfo>();

  for (const resource of resources) {
    if (!options.includeDisabled && !resource.enabled) {
      continue;
    }

    const extension = toHostExtensionInfo(resource.path, resource.metadata);
    if (!extension) {
      continue;
    }

    if (byName.has(extension.name)) {
      continue;
    }

    byName.set(extension.name, {
      ...extension,
      enabled: resource.enabled,
      metadata: resource.metadata,
    });
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

  if (!isValidExtensionName(name)) {
    return null;
  }

  return {
    name,
    path: absPath,
    kind,
  };
}

function resolveWorkspaceCwd(cwd: string | undefined, fallback?: string): string | null {
  const raw = cwd?.trim();
  if (!raw) {
    return fallback ?? null;
  }

  const expanded = raw === "~" || raw.startsWith("~/") ? raw.replace(/^~(?=\/|$)/, homedir()) : raw;
  return resolve(expanded);
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
