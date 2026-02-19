/**
 * Host environment management for oppi-server.
 *
 * Provides PATH resolution for local sessions and the `env` CLI subcommand.
 *
 * PATH resolution order (highest priority first):
 *   1. ~/.config/oppi/env file entries
 *   2. Well-known tool directories (auto-discovered)
 *   3. process.env.PATH baseline (LaunchAgent)
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// ─── Well-Known Directories ───

/**
 * Well-known tool directories that should be on PATH for local sessions.
 *
 * LaunchAgents / systemd services inherit a minimal PATH. Rather than sniffing
 * the user's shell (fragile, shell-specific — especially fish), we check for
 * common install locations and add them if they exist.
 */
export function wellKnownPathDirs(): string[] {
  const home = homedir();
  const candidates = [
    // Package managers & language toolchains
    join(home, ".local", "bin"),               // uv, pipx
    join(home, ".cargo", "bin"),               // rust / cargo
    join(home, ".bun", "bin"),                 // bun
    join(home, ".yarn", "bin"),                // yarn
    join(home, ".deno", "bin"),                // deno
    join(home, "go", "bin"),                   // go
    join(home, ".go", "bin"),                  // go (alt)
    // mise / asdf shims
    join(process.env.MISE_DATA_DIR || join(home, ".local", "share", "mise"), "shims"),
    // Homebrew (macOS)
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    // System
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
  ];
  return candidates.filter((d) => existsSync(d));
}

// ─── Env File ───

const ENV_FILE_PATH = join(homedir(), ".config", "oppi", "env");

/**
 * Load local-session environment overrides from ~/.config/oppi/env.
 *
 * Format (one per line, # comments, blank lines ignored):
 *   PATH=/opt/homebrew/bin:~/.local/bin:~/.cargo/bin
 *   EDITOR=nvim
 *
 * Tilde (~) in values is expanded to $HOME.
 */
export function loadHostEnv(envPath?: string): Record<string, string> {
  const filePath = envPath || process.env.OPPI_ENV_FILE || ENV_FILE_PATH;
  const overrides: Record<string, string> = {};

  if (!existsSync(filePath)) {
    return overrides;
  }

  try {
    const content = readFileSync(filePath, "utf-8");
    for (const rawLine of content.split("\n")) {
      const line = rawLine.trim();
      if (!line || line.startsWith("#")) continue;
      const eqIdx = line.indexOf("=");
      if (eqIdx <= 0) continue;
      const key = line.slice(0, eqIdx).trim();
      let value = line.slice(eqIdx + 1).trim();
      // Strip optional quotes
      if (
        (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))
      ) {
        value = value.slice(1, -1);
      }
      // Expand ~ to $HOME
      value = value.replaceAll("~", homedir());
      overrides[key] = value;
    }
  } catch {
    // Unreadable env file — continue with process.env only
  }

  return overrides;
}

// ─── PATH Merging ───

/** Deduplicated PATH merge. Earlier entries take priority. */
function mergePath(...sources: string[]): string {
  const seen = new Set<string>();
  const entries: string[] = [];
  for (const source of sources) {
    for (const p of source.split(":")) {
      if (p && !seen.has(p)) {
        seen.add(p);
        entries.push(p);
      }
    }
  }
  return entries.join(":");
}

/**
 * Build the merged local-session environment.
 *
 * PATH resolution order (highest priority first):
 *   1. ~/.config/oppi/env PATH entries
 *   2. Well-known tool directories (homebrew, uv, cargo, etc.)
 *   3. process.env.PATH (LaunchAgent baseline)
 *
 * Non-PATH overrides from the env file are applied directly.
 */
export function buildHostEnv(overrides: Record<string, string>): Record<string, string> {
  const env = { ...process.env } as Record<string, string>;

  // Build PATH: env file > well-known dirs > process.env.PATH
  const wellKnown = wellKnownPathDirs().join(":");
  env.PATH = mergePath(
    overrides.PATH || "",
    wellKnown,
    process.env.PATH || "",
  );

  // Apply non-PATH overrides
  for (const [key, value] of Object.entries(overrides)) {
    if (key !== "PATH") {
      env[key] = value;
    }
  }

  return env;
}

// ─── Cached Singletons ───

/** Loaded once at module init. */
const HOST_ENV_OVERRIDES = loadHostEnv();

/** Full merged environment for local session spawns. */
export const HOST_ENV = buildHostEnv(HOST_ENV_OVERRIDES);

/** Just the PATH component for quick access. */
export const HOST_PATH = HOST_ENV.PATH || process.env.PATH || "/usr/local/bin:/usr/bin:/bin";

// ─── CLI: env init ───

export function envInit(): void {
  const currentPath = process.env.PATH || "";
  if (!currentPath) {
    console.error("$PATH is empty — run this from your interactive shell");
    process.exit(1);
  }

  // Deduplicate and normalize: replace $HOME with ~ for portability
  const home = homedir();
  const seen = new Set<string>();
  const dedupedEntries: string[] = [];
  for (const p of currentPath.split(":")) {
    if (p && !seen.has(p)) {
      seen.add(p);
      dedupedEntries.push(p.startsWith(home) ? p.replace(home, "~") : p);
    }
  }

  const lines = [
    "# oppi local session environment",
    "# Generated by: oppi env init",
    `# Date: ${new Date().toISOString()}`,
    "#",
    "# Environment variables for local sessions.",
    "# The server reads this at startup — restart after editing.",
    "# ~ is expanded to $HOME. One KEY=VALUE per line.",
    "",
    `PATH=${dedupedEntries.join(":")}`,
    "",
  ];

  const dir = join(homedir(), ".config", "oppi");
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
  }
  writeFileSync(ENV_FILE_PATH, lines.join("\n"));

  return printEnvInitResult(ENV_FILE_PATH, dedupedEntries.length);
}

function printEnvInitResult(path: string, count: number): void {
  console.log(`  ✓ Wrote ${path}`);
  console.log(`    ${count} PATH entries captured`);
  console.log("    Restart oppi to apply.");
}

// ─── CLI: env show ───

export function envShow(): void {
  const overrides = loadHostEnv();
  const merged = buildHostEnv(overrides);
  const hasEnvFile = existsSync(ENV_FILE_PATH);

  console.log(
    `  Env file: ${hasEnvFile ? ENV_FILE_PATH : "none (using well-known dirs only)"}`,
  );
  console.log("");
  console.log("  PATH entries:");

  const envFilePaths = new Set(
    (overrides.PATH || "").split(":").filter(Boolean),
  );

  for (const p of (merged.PATH || "").split(":")) {
    let tier: string;
    if (envFilePaths.has(p)) {
      tier = "●"; // from env file
    } else if (
      p.includes(".local/bin") || p.includes(".cargo/bin") ||
      p.includes(".bun/") || p.includes("homebrew")
    ) {
      tier = "◆"; // well-known bootstrap
    } else {
      tier = "○"; // inherited from process.env
    }
    console.log(`    ${tier} ${p}`);
  }
  console.log("");
  console.log("    ● env file  ◆ well-known  ○ inherited");

  // Non-PATH overrides
  const nonPath = Object.entries(overrides).filter(([k]) => k !== "PATH");
  if (nonPath.length > 0) {
    console.log("");
    console.log("  Other overrides:");
    for (const [k, v] of nonPath) {
      console.log(`    ${k}=${v}`);
    }
  }
}
