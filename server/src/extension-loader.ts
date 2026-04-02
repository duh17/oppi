/**
 * Workspace extension resolution.
 *
 * Resolves named extensions from pi host extension locations for workspace-related flows.
 */

import { existsSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { extname, join, resolve } from "node:path";

import { isManagedExtensionName } from "../extensions/first-party.js";

const HOST_EXTENSIONS_DIR = join(homedir(), ".pi", "agent", "extensions");

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

/** Validate extension name accepted by workspace API. */
export function isValidExtensionName(name: string): boolean {
  return EXTENSION_NAME_RE.test(name.trim());
}

/**
 * List host extensions available for workspace selection.
 *
 * Scans the global host directory (`~/.pi/agent/extensions`) and, when `cwd`
 * is provided, the project-local directory (`<cwd>/.pi/extensions`). Managed
 * first-party extensions are excluded.
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
    if (isManagedExtensionName(normalized)) {
      warnings.push(`Ignoring managed extension in explicit list: ${requested}`);
      continue;
    }

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
    const kind = detectKind(absPath);
    if (!kind) {
      continue;
    }

    const ext = extname(entry);
    let name = entry;

    if (kind === "file") {
      if (ext !== ".ts" && ext !== ".js") {
        continue;
      }
      name = entry.slice(0, -ext.length);

      // Skip test files — they are not loadable extensions.
      if (name.endsWith(".test") || name.endsWith(".spec")) {
        continue;
      }
    }

    if (!isValidExtensionName(name) || isManagedExtensionName(name)) {
      continue;
    }

    const existing = byName.get(name);
    if (!existing || (existing.kind === "file" && kind === "directory")) {
      byName.set(name, { name, path: absPath, kind });
    }
  }

  return Array.from(byName.values());
}

function getProjectExtensionsDir(cwd: string | undefined): string | null {
  const raw = cwd?.trim();
  if (!raw) {
    return null;
  }

  const expanded = raw === "~" || raw.startsWith("~/") ? raw.replace(/^~(?=\/|$)/, homedir()) : raw;
  return join(resolve(expanded), ".pi", "extensions");
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
