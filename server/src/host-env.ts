/**
 * Runtime environment resolution for oppi-server.
 *
 * Environment configuration is explicit and sourced from config.json:
 *   - runtimePathEntries: string[]
 *   - runtimeEnv: Record<string, string>
 *
 * One addition is not from config: the directory of OPPI_NODE goes last on the
 * runtime PATH (see installerNodeDir).
 */

import { accessSync, constants, existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";
import type { ServerConfig } from "./types.js";

const initialHostEnv = { ...process.env } as Record<string, string>;
let lastAppliedRuntimeEnvKeys = new Set<string>();

export interface ResolvedHostEnv {
  configuredPathEntries: string[];
  env: Record<string, string>;
}

function expandHome(value: string): string {
  if (value === "~" || value.startsWith("~/")) {
    return value.replace(/^~(?=\/|$)/, homedir());
  }
  return value;
}

function normalizePathEntries(entries: string[] | undefined): string[] {
  if (!entries) return [];

  const seen = new Set<string>();
  const out: string[] = [];

  for (const raw of entries) {
    const entry = expandHome(raw.trim());
    if (!entry || seen.has(entry)) continue;
    seen.add(entry);
    out.push(entry);
  }

  return out;
}

/** Deduplicated PATH build from configured entries only (explicit mode). */
function buildPath(entries: string[]): string {
  const seen = new Set<string>();
  const out: string[] = [];

  for (const entry of entries) {
    if (!entry || seen.has(entry)) continue;
    seen.add(entry);
    out.push(entry);
  }

  return out.join(":");
}

/**
 * install.sh's launcher, and the service it installs, set OPPI_NODE to the Node
 * they run, which may be the only Node on the machine (~/.oppi/runtime/node).
 * Its directory goes last on the runtime PATH so sessions and the npm update
 * check find node and npm, while a Node the user configured still wins. It is
 * appended here rather than written into config, which would pin the default
 * runtimePathEntries for users who never set them.
 */
function installerNodeDir(baseEnv: Record<string, string>): string | undefined {
  const node = baseEnv.OPPI_NODE;
  return node && isAbsolute(node) ? dirname(node) : undefined;
}

export function buildHostEnv(
  config: ServerConfig,
  baseEnv: Record<string, string> = initialHostEnv,
): Record<string, string> {
  const env = { ...baseEnv } as Record<string, string>;
  const configuredEntries = normalizePathEntries(config.runtimePathEntries);
  const nodeDir = installerNodeDir(baseEnv);

  // Explicit runtime PATH: configured entries, then the installer's Node.
  env.PATH = buildPath(nodeDir ? [...configuredEntries, nodeDir] : configuredEntries);
  // An installer-to-service signal; sessions run `oppi` through the launcher, which sets it.
  delete env.OPPI_NODE;

  for (const [key, raw] of Object.entries(config.runtimeEnv || {})) {
    env[key] = expandHome(raw);
  }

  return env;
}

export function resolveHostEnv(
  config: ServerConfig,
  baseEnv: Record<string, string> = initialHostEnv,
): ResolvedHostEnv {
  const configuredPathEntries = normalizePathEntries(config.runtimePathEntries);
  const env = buildHostEnv(config, baseEnv);

  return {
    configuredPathEntries,
    env,
  };
}

/** Apply resolved runtime environment to process.env (used by server runtime). */
export function applyHostEnv(
  config: ServerConfig,
  baseEnv: Record<string, string> = initialHostEnv,
): ResolvedHostEnv {
  const resolved = resolveHostEnv(config, baseEnv);
  const nextRuntimeEnvKeys = new Set(Object.keys(config.runtimeEnv || {}));

  for (const key of lastAppliedRuntimeEnvKeys) {
    if (nextRuntimeEnvKeys.has(key)) {
      continue;
    }
    const restoredValue = resolved.env[key];
    if (typeof restoredValue === "string") {
      process.env[key] = restoredValue;
    } else {
      delete process.env[key];
    }
  }

  for (const [key, value] of Object.entries(resolved.env)) {
    process.env[key] = value;
  }
  // Sessions inherit process.env; keep the installer signal out of it (see buildHostEnv).
  delete process.env.OPPI_NODE;

  lastAppliedRuntimeEnvKeys = nextRuntimeEnvKeys;
  return resolved;
}

/** Prepend an internal executable directory without duplicating PATH entries. */
export function prependPathEntry(pathValue: string | undefined, entry: string): string {
  const normalized = entry.trim();
  const entries = (pathValue ?? "").split(":").filter(Boolean);
  if (!normalized) return entries.join(":");
  return [normalized, ...entries.filter((candidate) => candidate !== normalized)].join(":");
}

/** Resolve a binary from a PATH string. Returns absolute path if found. */
export function resolveExecutableOnPath(executable: string, pathValue?: string): string | null {
  const path = pathValue || process.env.PATH || "";
  for (const dir of path.split(":")) {
    if (!dir) continue;
    const candidate = join(dir, executable);
    if (!existsSync(candidate)) continue;
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // Not executable; keep searching.
    }
  }
  return null;
}
