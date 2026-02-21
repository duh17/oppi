import { appendFileSync, existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * Path to the shared fetch domain allowlist.
 *
 * Format: one domain per line. Supports:
 *   example.com              — exact domain + subdomains
 *   github.com/org           — github.com scoped to org (ignored here, treated as github.com)
 *   github.com/owner/repo    — scoped (ignored here, treated as github.com)
 *   # comments and blank lines
 */
const FETCH_ALLOWLIST_PATH = join(homedir(), ".config", "fetch", "allowed_domains.txt");

/** Cached allowlist. Loaded once at module init, reloaded on PolicyEngine construction. */
let cachedAllowedDomains: Set<string> | null = null;
let cachedAllowlistMtime = 0;

/**
 * Load the shared fetch domain allowlist.
 *
 * Extracts bare domains from entries like "github.com/org/repo" → "github.com".
 * Returns a Set of lowercase domains.
 */
export function loadFetchAllowlist(overridePath?: string): Set<string> {
  const filePath = overridePath || FETCH_ALLOWLIST_PATH;
  try {
    // Only use cache for the default path
    if (!overridePath) {
      const { mtimeMs } = statSync(filePath);
      if (cachedAllowedDomains && mtimeMs === cachedAllowlistMtime) {
        return cachedAllowedDomains;
      }
    }

    const content = readFileSync(filePath, "utf-8");
    const domains = new Set<string>();

    for (const line of content.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;

      // Extract the domain part (strip path components like /org/repo)
      // "github.com/anthropics" → "github.com"
      // "docs.python.org" → "docs.python.org"
      const slashIdx = trimmed.indexOf("/");
      const domain = slashIdx > 0 ? trimmed.slice(0, slashIdx) : trimmed;
      domains.add(domain.toLowerCase());
    }

    if (!overridePath) {
      const { mtimeMs } = statSync(filePath);
      cachedAllowedDomains = domains;
      cachedAllowlistMtime = mtimeMs;
    }
    return domains;
  } catch {
    // File doesn't exist or unreadable — empty allowlist
    return new Set();
  }
}

/**
 * Add a domain to the shared fetch allowlist.
 * No-op if the domain is already present.
 * Invalidates the in-memory cache.
 */
export function addDomainToAllowlist(domain: string, allowlistPath?: string): void {
  const path = allowlistPath || FETCH_ALLOWLIST_PATH;
  const lower = domain.toLowerCase().trim();
  if (!lower) return;

  // Check if already present
  const existing = loadFetchAllowlist(path);
  if (existing.has(lower)) return;

  // Append to file
  try {
    const content = existsSync(path) ? readFileSync(path, "utf-8") : "";
    const needsNewline = content.length > 0 && !content.endsWith("\n");
    appendFileSync(path, (needsNewline ? "\n" : "") + lower + "\n", { mode: 0o644 });

    // Invalidate cache
    cachedAllowedDomains = null;
    cachedAllowlistMtime = 0;
  } catch (err) {
    console.error(`[policy] Failed to add domain to allowlist: ${err}`);
  }
}

/**
 * Remove a domain from the shared fetch allowlist.
 * Preserves comments and blank lines.
 * Invalidates the in-memory cache.
 */
export function removeDomainFromAllowlist(domain: string, allowlistPath?: string): void {
  const path = allowlistPath || FETCH_ALLOWLIST_PATH;
  const lower = domain.toLowerCase().trim();
  if (!lower) return;

  if (!existsSync(path)) return;

  try {
    const content = readFileSync(path, "utf-8");
    const lines = content.split("\n");
    const filtered = lines.filter((line) => {
      const trimmed = line.trim().toLowerCase();
      // Preserve comments and blanks
      if (!trimmed || trimmed.startsWith("#")) return true;
      // Remove exact match (strip /path suffix for comparison)
      const slashIdx = trimmed.indexOf("/");
      const lineDomain = slashIdx > 0 ? trimmed.slice(0, slashIdx) : trimmed;
      return lineDomain !== lower;
    });
    writeFileSync(path, filtered.join("\n"), { mode: 0o644 });

    // Invalidate cache
    cachedAllowedDomains = null;
    cachedAllowlistMtime = 0;
  } catch (err) {
    console.error(`[policy] Failed to remove domain from allowlist: ${err}`);
  }
}

/**
 * List all domains in the shared fetch allowlist.
 * Returns sorted unique domains (strips path suffixes).
 */
export function listAllowlistDomains(allowlistPath?: string): string[] {
  const domains = loadFetchAllowlist(allowlistPath);
  return Array.from(domains).sort();
}
