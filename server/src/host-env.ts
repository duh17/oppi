/**
 * Runtime environment resolution for oppi-server.
 *
 * Environment configuration is explicit and sourced from config.json:
 *   - runtimePathEntries: string[]
 *   - runtimeEnv: Record<string, string>
 */

import { accessSync, constants, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ServerConfig } from "./types.js";

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

export function buildHostEnv(config: ServerConfig): Record<string, string> {
  const env = { ...process.env } as Record<string, string>;
  const configuredEntries = normalizePathEntries(config.runtimePathEntries);

  // Explicit runtime PATH: configured entries only.
  env.PATH = buildPath(configuredEntries);

  for (const [key, raw] of Object.entries(config.runtimeEnv || {})) {
    env[key] = expandHome(raw);
  }

  return env;
}

export function resolveHostEnv(config: ServerConfig): ResolvedHostEnv {
  const configuredPathEntries = normalizePathEntries(config.runtimePathEntries);
  const env = buildHostEnv(config);

  return {
    configuredPathEntries,
    env,
  };
}

/** Apply resolved runtime environment to process.env (used by server runtime). */
export function applyHostEnv(config: ServerConfig): ResolvedHostEnv {
  const resolved = resolveHostEnv(config);
  for (const [key, value] of Object.entries(resolved.env)) {
    process.env[key] = value;
  }
  return resolved;
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
