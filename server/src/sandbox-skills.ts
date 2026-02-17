/**
 * Sandbox skill management — sync skills, create shims, manage fetch allowlist.
 *
 * Skills live at the workspace level (shared across sessions). Each session
 * gets a relative symlink from agent/skills → ../../../skills so pi discovers
 * them via PI_CODING_AGENT_DIR.
 */

import {
  existsSync,
  mkdirSync,
  cpSync,
  writeFileSync,
  rmSync,
  symlinkSync,
  lstatSync,
  readlinkSync,
  unlinkSync,
} from "node:fs";
import { join, dirname, relative, resolve } from "node:path";
import { homedir } from "node:os";
import { copyFileDereferenced, isNewer } from "./sync.js";
import type { SkillRegistry } from "./skills.js";

// ─── Constants ───

const BUNDLED_SKILLS_DIR = join(dirname(new URL(import.meta.url).pathname), "..", "skills");

/**
 * CLI shim binaries — scripts in skills that should be on $PATH.
 * Maps bin name → relative path from skills dir.
 * Shims are created only for skills that are actually installed.
 */
const SKILL_SHIMS: Record<string, { skill: string; path: string }> = {
  search: { skill: "search", path: "search/scripts/search" },
  fetch: { skill: "fetch", path: "fetch/scripts/fetch" },
  "fetch-allow": { skill: "fetch", path: "fetch/scripts/fetch-allow" },
};

/** Default allowed domains for the fetch skill (container-safe defaults). */
const DEFAULT_FETCH_ALLOWLIST = `# Fetch domain allowlist (oppi-server defaults)
# Add entries: fetch --allow-domain example.com

# Documentation
docs.python.org
doc.rust-lang.org
developer.mozilla.org
devdocs.io
developer.apple.com

# Code hosting
github.com
raw.githubusercontent.com
gitlab.com

# Knowledge
en.wikipedia.org
stackoverflow.com
arxiv.org

# Tech
news.ycombinator.com
go.dev
pytorch.org
huggingface.co
docs.anthropic.com
example.com
`;

// ─── Skill Sync ───

/**
 * Sync requested skills into the workspace-level skills/ directory.
 *
 * Skills are shared across all sessions in a workspace. Each session's
 * agent/skills/ is a relative symlink to the workspace skills dir.
 *
 * Source priority: SkillRegistry (host paths) > host dotfiles > bundled.
 * Returns list of skill names that were actually installed.
 */
export function syncSkills(
  skillsDir: string,
  requestedSkills: string[],
  skillRegistry: SkillRegistry | null,
  opts?: { force?: boolean },
): string[] {
  if (!existsSync(skillsDir)) {
    mkdirSync(skillsDir, { recursive: true });
  }

  const hostSkillsDir = join(homedir(), ".pi", "agent", "skills");
  const installed: string[] = [];

  for (const name of requestedSkills) {
    const dest = join(skillsDir, name);

    // Source priority: registry (exact host path) > host dotfiles > bundled
    const registryPath = skillRegistry?.getPath(name);
    const hostSrc = join(hostSkillsDir, name);
    const bundledSrc = join(BUNDLED_SKILLS_DIR, name);

    let src: string | null = null;
    if (registryPath && existsSync(registryPath)) {
      src = registryPath;
    } else if (existsSync(hostSrc)) {
      src = hostSrc;
    } else if (existsSync(bundledSrc)) {
      src = bundledSrc;
    }

    if (!src) {
      console.log(`[sandbox] ⚠ Skill "${name}" not found, skipping`);
      continue;
    }

    // Re-copy if forced, source is newer, or dest doesn't exist
    if (!existsSync(dest) || opts?.force || isNewer(src, dest)) {
      if (existsSync(dest)) rmSync(dest, { recursive: true });
      cpSync(src, dest, { recursive: true, dereference: true });
    }

    installed.push(name);
  }

  if (installed.length > 0) {
    console.log(`[sandbox] Synced ${installed.length} skill(s): ${installed.join(", ")}`);
  }

  return installed;
}

/**
 * Link session's agent/skills/ to the workspace-level skills dir.
 *
 * Uses a relative symlink so it works both on the host and inside the
 * container (where the bind mount root differs from the host path).
 *
 * Layout: sessions/<sid>/agent/skills → ../../../skills
 */
export function linkSessionSkills(agentDir: string, workspaceSkillsDir: string): void {
  const sessionSkillsLink = join(agentDir, "skills");

  // If there's an old directory (pre-workspace-level migration), remove it
  if (existsSync(sessionSkillsLink)) {
    const stat = lstatSync(sessionSkillsLink);
    if (stat.isSymbolicLink()) {
      // Already a symlink — check if it points to the right place
      const target = readlinkSync(sessionSkillsLink);
      const resolvedTarget = resolve(dirname(sessionSkillsLink), target);
      if (resolvedTarget === resolve(workspaceSkillsDir)) return;
      // Wrong target — re-create
      unlinkSync(sessionSkillsLink);
    } else if (stat.isDirectory()) {
      // Old per-session skills dir — remove it
      rmSync(sessionSkillsLink, { recursive: true });
    }
  }

  // Create relative symlink: agent/skills → ../../../skills
  const relTarget = relative(dirname(sessionSkillsLink), workspaceSkillsDir);
  symlinkSync(relTarget, sessionSkillsLink);
}

/**
 * Create symlink shims so skill scripts are on $PATH.
 *
 * Location: sessions/<sid>/bin
 * Only creates shims for skills that were actually installed.
 */
export function createSkillShims(
  sessionRootDir: string,
  agentDir: string,
  skillsDir: string,
  installedSkills: string[],
): void {
  const binDirs = [join(sessionRootDir, "bin")];
  const installedSet = new Set(installedSkills);

  for (const binDir of binDirs) {
    if (!existsSync(binDir)) {
      mkdirSync(binDir, { recursive: true });
    }

    for (const [binName, shim] of Object.entries(SKILL_SHIMS)) {
      const link = join(binDir, binName);

      // Only create shim if the skill is installed in this workspace
      if (!installedSet.has(shim.skill)) {
        // Clean up stale shims from previous runs with different workspaces
        if (existsSync(link)) rmSync(link);
        continue;
      }

      const target = join(skillsDir, shim.path);
      if (!existsSync(target)) continue;

      if (existsSync(link)) rmSync(link);
      const relTarget = relative(binDir, target);
      symlinkSync(relTarget, link);
    }
  }
}

/**
 * Write a .profile in the session HOME so login shells preserve our PATH.
 *
 * Problem: Alpine's /etc/profile does `export PATH="/usr/local/sbin:..."`,
 * which wipes the session bin dir set via `container exec -e PATH=...`.
 * When pi spawns `bash` for tool calls, it gets a login shell that sources
 * /etc/profile before ~/.profile, so our PATH override wins.
 */
export function writeSessionProfile(
  piDir: string,
  sessionId: string,
  containerWorkspaceRoot: string,
): void {
  const profilePath = join(piDir, ".profile");
  const containerBinDir = `${containerWorkspaceRoot}/sessions/${sessionId}/bin`;
  const containerAgentBinDir = `${containerWorkspaceRoot}/sessions/${sessionId}/agent/bin`;
  const profile = [
    "# Pi Remote session profile — preserves skill shims on PATH",
    // eslint-disable-next-line no-useless-escape
    `export PATH="${containerBinDir}:${containerAgentBinDir}:/home/pi/.pi/bin:\$PATH"`,
    "",
  ].join("\n");
  writeFileSync(profilePath, profile);
}

/**
 * Write a default fetch domain allowlist so fetch works out of the box.
 * Skips if the user already has one synced.
 */
export function writeFetchAllowlist(piDir: string): void {
  const configDir = join(piDir, ".config", "fetch");
  const allowlistPath = join(configDir, "allowed_domains.txt");

  if (existsSync(allowlistPath)) return;

  // Try to sync from host first
  const hostAllowlist = join(homedir(), ".config", "fetch", "allowed_domains.txt");
  if (existsSync(hostAllowlist)) {
    mkdirSync(configDir, { recursive: true });
    copyFileDereferenced(hostAllowlist, allowlistPath);
    return;
  }

  // Fall back to sensible defaults
  mkdirSync(configDir, { recursive: true });
  writeFileSync(allowlistPath, DEFAULT_FETCH_ALLOWLIST);
}
