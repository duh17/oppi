/**
 * Workspace extension resolution.
 *
 * Supports two modes:
 * - legacy (default): auto-load legacy memory/todo host extensions
 * - explicit: load only extensions listed in workspace.extensions
 *
 * Backward compatibility:
 * Existing workspaces without extensionMode/extensions continue using legacy mode.
 */

import { existsSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { extname, join } from "node:path";
import type { Workspace } from "./types.js";

export const HOST_EXTENSIONS_DIR = join(homedir(), ".pi", "agent", "extensions");
export const HOST_MEMORY_EXTENSION = join(HOST_EXTENSIONS_DIR, "memory.ts");
export const HOST_TODOS_EXTENSION = join(HOST_EXTENSIONS_DIR, "todos.ts");

const EXTENSION_NAME_RE = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/;

export type WorkspaceExtensionMode = "legacy" | "explicit";

export interface ResolvedExtension {
  /** Normalized extension name (without file extension). */
  name: string;
  /** Absolute host path to extension entry (file or directory). */
  path: string;
  /** Entry kind for installation behavior. */
  kind: "file" | "directory";
}

export interface ResolveWorkspaceExtensionsOptions {
  /** Enable legacy auto-loading for memory/todos extensions. */
  legacyEnabled: boolean;
}

export interface ResolveWorkspaceExtensionsResult {
  mode: WorkspaceExtensionMode;
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

/** Validate extension name accepted by workspace API. */
export function isValidExtensionName(name: string): boolean {
  return EXTENSION_NAME_RE.test(name.trim());
}

/**
 * List host extensions available for explicit workspace selection.
 *
 * Scans ~/.pi/agent/extensions and returns discoverable entries.
 * Managed extensions (permission-gate) are excluded.
 */
export function listHostExtensions(): HostExtensionInfo[] {
  if (!existsSync(HOST_EXTENSIONS_DIR)) {
    return [];
  }

  const byName = new Map<string, HostExtensionInfo>();

  for (const entry of readdirSync(HOST_EXTENSIONS_DIR)) {
    if (entry.startsWith(".")) {
      continue;
    }

    const absPath = join(HOST_EXTENSIONS_DIR, entry);
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
    }

    if (!isValidExtensionName(name)) {
      continue;
    }

    if (name === "permission-gate") {
      continue;
    }

    const existing = byName.get(name);
    if (!existing) {
      byName.set(name, { name, path: absPath, kind });
      continue;
    }

    // Prefer directory entries over files when both exist.
    if (existing.kind === "file" && kind === "directory") {
      byName.set(name, { name, path: absPath, kind });
    }
  }

  return Array.from(byName.values()).sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * Resolve workspace extension paths for spawn/install.
 *
 * Mode selection:
 * 1. workspace.extensionMode when present
 * 2. explicit when workspace.extensions is present
 * 3. legacy fallback (for backward compatibility)
 */
export function resolveWorkspaceExtensions(
  workspace: Workspace | undefined,
  options: ResolveWorkspaceExtensionsOptions,
): ResolveWorkspaceExtensionsResult {
  const explicitNames = workspace?.extensions;
  const mode: WorkspaceExtensionMode =
    workspace?.extensionMode ?? (Array.isArray(explicitNames) ? "explicit" : "legacy");

  if (mode === "explicit") {
    return resolveExplicitExtensions(explicitNames ?? []);
  }

  return resolveLegacyExtensions(workspace, options);
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

function resolveExplicitExtensions(names: string[]): ResolveWorkspaceExtensionsResult {
  const warnings: string[] = [];
  const resolved: ResolvedExtension[] = [];
  const seen = new Set<string>();

  for (const raw of names) {
    const requested = raw.trim();
    if (requested.length === 0) {
      continue;
    }

    if (!isValidExtensionName(requested)) {
      warnings.push(`Ignoring invalid extension name: ${requested}`);
      continue;
    }

    const ext = resolveByName(requested);
    if (!ext) {
      warnings.push(`Extension not found: ${requested}`);
      continue;
    }

    // Permission gate is managed by oppi-server and loaded separately.
    if (ext.name === "permission-gate") {
      warnings.push(`Ignoring managed extension in explicit list: ${requested}`);
      continue;
    }

    if (seen.has(ext.path)) {
      continue;
    }

    seen.add(ext.path);
    resolved.push(ext);
  }

  return {
    mode: "explicit",
    extensions: resolved,
    warnings,
  };
}

function resolveLegacyExtensions(
  workspace: Workspace | undefined,
  options: ResolveWorkspaceExtensionsOptions,
): ResolveWorkspaceExtensionsResult {
  if (!options.legacyEnabled) {
    return {
      mode: "legacy",
      extensions: [],
      warnings: [],
    };
  }

  const warnings: string[] = [];
  const extensions: ResolvedExtension[] = [];

  if (workspace?.memoryEnabled) {
    const memory = resolveKnownPath("memory", HOST_MEMORY_EXTENSION);
    if (memory) {
      extensions.push(memory);
    } else {
      warnings.push(`Legacy memory extension not found: ${HOST_MEMORY_EXTENSION}`);
    }
  }

  const todos = resolveKnownPath("todos", HOST_TODOS_EXTENSION);
  if (todos) {
    extensions.push(todos);
  }

  return {
    mode: "legacy",
    extensions,
    warnings,
  };
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

function resolveKnownPath(name: string, absPath: string): ResolvedExtension | null {
  const kind = detectKind(absPath);
  if (!kind) return null;

  return {
    name,
    path: absPath,
    kind,
  };
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
    // Fall back to suffix-based inference to keep behavior deterministic.
    const suffix = extname(absPath);
    if (suffix === ".ts" || suffix === ".js") {
      return "file";
    }
    return "directory";
  }
}
