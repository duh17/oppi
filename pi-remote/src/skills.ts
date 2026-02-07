/**
 * Skill registry — discovers and catalogs available skills from the host.
 *
 * Scans ~/.pi/agent/skills/ for SKILL.md files, extracts metadata,
 * and determines container compatibility. Workspaces reference skills
 * by name from this pool.
 */

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, basename } from "node:path";
import { homedir } from "node:os";

// ─── Types ───

export interface SkillInfo {
  /** Skill name (directory name, e.g. "searxng"). */
  name: string;
  /** Human-readable description from SKILL.md frontmatter. */
  description: string;
  /** Whether this skill can run inside an Apple container. */
  containerSafe: boolean;
  /** Whether the skill has executable scripts (needs bin shims). */
  hasScripts: boolean;
  /** Host filesystem path to the skill directory. */
  path: string;
}

/** Markers in SKILL.md that indicate host-only requirements. */
const HOST_ONLY_MARKERS = [
  "MLX", "mlx", "lmstudio", "LM Studio",
  "/Users/", "homebrew",
  "mac-studio", "mac-mini",
  // tmux-based skills spawn panes on the host
  "tmux send-keys", "tmux new-window",
];

/**
 * Skills known to work in containers despite having marker false positives.
 * These reference "host" in docs but actually work fine via network access.
 */
const CONTAINER_SAFE_OVERRIDES = new Set([
  "searxng",       // connects to host SearXNG via network
  "fetch",         // standalone script, no host deps
  "web-browser",   // uses Chromium inside container
  "weather",       // uses fetch skill
  "youtube-transcript",  // uses yt-dlp (installed in container)
]);

/**
 * Skills that definitely need host access and can't run in containers.
 */
const HOST_ONLY_SKILLS = new Set([
  "tmux",              // needs host tmux
  "code-simplifier",   // spawns tmux agent
  "private-agent",     // spawns tmux agent with LM Studio
  "dotfiles-manage",   // manages host dotfiles
  "dotfiles-sync",     // syncs host dotfiles to other machines
  "audio-transcribe",  // needs MLX on host
]);

// ─── Skill Registry ───

export class SkillRegistry {
  private skills: Map<string, SkillInfo> = new Map();
  private scanDirs: string[];

  constructor(extraDirs?: string[]) {
    this.scanDirs = [
      join(homedir(), ".pi", "agent", "skills"),
      ...(extraDirs || []),
    ];
  }

  /**
   * Scan host skill directories and build the registry.
   * Call on startup and when skills may have changed.
   */
  scan(): void {
    this.skills.clear();

    for (const dir of this.scanDirs) {
      if (!existsSync(dir)) continue;

      for (const entry of readdirSync(dir)) {
        const skillDir = join(dir, entry);
        try {
          if (!statSync(skillDir).isDirectory()) continue;
        } catch {
          // Dangling symlink or permission error — skip
          continue;
        }

        const skillMd = join(skillDir, "SKILL.md");
        if (!existsSync(skillMd)) continue;

        // Skip if already registered (first dir wins)
        if (this.skills.has(entry)) continue;

        const info = this.parseSkill(entry, skillDir, skillMd);
        if (info) {
          this.skills.set(entry, info);
        }
      }
    }

    console.log(`[skills] Discovered ${this.skills.size} skill(s): ${Array.from(this.skills.keys()).join(", ")}`);
  }

  /** Get all available skills. */
  list(): SkillInfo[] {
    return Array.from(this.skills.values());
  }

  /** Get a single skill by name. */
  get(name: string): SkillInfo | undefined {
    return this.skills.get(name);
  }

  /** Get the host path for a skill (for syncing into containers). */
  getPath(name: string): string | undefined {
    return this.skills.get(name)?.path;
  }

  /** Get skill names that are safe to use in containers. */
  listContainerSafe(): SkillInfo[] {
    return this.list().filter(s => s.containerSafe);
  }

  // ─── Internal ───

  private parseSkill(name: string, dir: string, skillMdPath: string): SkillInfo | null {
    const content = readFileSync(skillMdPath, "utf-8");

    // Extract description from YAML frontmatter
    const description = this.extractDescription(content);
    if (!description) {
      console.warn(`[skills] Skipping "${name}" — no description in SKILL.md`);
      return null;
    }

    // Check for executable scripts
    const scriptsDir = join(dir, "scripts");
    const hasScripts = existsSync(scriptsDir) && readdirSync(scriptsDir).length > 0;

    // Determine container compatibility
    const containerSafe = this.isContainerSafe(name, content);

    return {
      name,
      description,
      containerSafe,
      hasScripts,
      path: dir,
    };
  }

  private extractDescription(content: string): string {
    // Parse YAML frontmatter between --- delimiters
    const fmMatch = content.match(/^---\s*\n([\s\S]*?)\n---/);
    if (!fmMatch) return "";

    const frontmatter = fmMatch[1];

    // Extract description field (handles quoted and unquoted values)
    const descMatch = frontmatter.match(/^description:\s*"?([^"\n]+)"?\s*$/m);
    if (!descMatch) return "";

    return descMatch[1].trim();
  }

  private isContainerSafe(name: string, content: string): boolean {
    // Explicit overrides first
    if (HOST_ONLY_SKILLS.has(name)) return false;
    if (CONTAINER_SAFE_OVERRIDES.has(name)) return true;

    // Heuristic: check for host-only markers in content
    for (const marker of HOST_ONLY_MARKERS) {
      if (content.includes(marker)) return false;
    }

    return true;
  }
}
