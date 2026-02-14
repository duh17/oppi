/**
 * Skill registry — discovers and catalogs available skills from the host
 * and manages user-created skills.
 *
 * Built-in skills: Scans ~/.pi/agent/skills/ for SKILL.md files, extracts
 * metadata, and determines container compatibility. Workspaces reference
 * skills by name from this pool.
 *
 * User skills: Stored in ~/.config/oppi/skills/<userId>/<name>/ with a
 * SKILL.md file. Saved from session workspaces via REST API. Merged
 * into the registry alongside built-ins (user skills can shadow built-ins).
 */

import {
  cpSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
} from "node:fs";
import { join } from "node:path";
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

/** Extended skill info with SKILL.md content and file tree. */
export interface SkillDetail {
  skill: SkillInfo;
  /** Raw SKILL.md content. */
  content: string;
  /** Relative file paths in the skill directory (excludes junk like __pycache__). */
  files: string[];
}

/** Markers in SKILL.md that indicate host-only requirements. */
const HOST_ONLY_MARKERS = [
  "MLX",
  "mlx",
  "lmstudio",
  "LM Studio",
  "/Users/",
  "homebrew",
  "my-mac",
  "mac-mini",
  // tmux-based skills spawn panes on the host
  "tmux send-keys",
  "tmux new-window",
];

/**
 * Skills known to work in containers despite having marker false positives.
 * These reference "host" in docs but actually work fine via network access.
 */
const CONTAINER_SAFE_OVERRIDES = new Set([
  "searxng", // connects to host SearXNG via network
  "fetch", // standalone script, no host deps
  "web-browser", // uses Chromium inside container
  "weather", // uses fetch skill
  "youtube-transcript", // uses yt-dlp (installed in container)
]);

/**
 * Skills that definitely need host access and can't run in containers.
 */
const HOST_ONLY_SKILLS = new Set([
  "tmux", // needs host tmux
  "code-simplifier", // spawns tmux agent
  "private-agent", // spawns tmux agent with LM Studio
  "dotfiles-manage", // manages host dotfiles
  "dotfiles-sync", // syncs host dotfiles to other machines
  "audio-transcribe", // needs MLX on host
]);

// ─── Skill Registry ───

export class SkillRegistry {
  private skills: Map<string, SkillInfo> = new Map();
  private scanDirs: string[];

  constructor(extraDirs?: string[]) {
    this.scanDirs = [join(homedir(), ".pi", "agent", "skills"), ...(extraDirs || [])];
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

    console.log(
      `[skills] Discovered ${this.skills.size} skill(s): ${Array.from(this.skills.keys()).join(", ")}`,
    );
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
    return this.list().filter((s) => s.containerSafe);
  }

  /**
   * Register user skills into the registry so they're discoverable
   * by name (used by workspace skill lists and sandbox sync).
   *
   * User skills are registered with the same parsing as built-ins.
   * They can shadow built-in skills (user skill takes precedence).
   */
  registerUserSkills(skills: UserSkill[]): void {
    for (const us of skills) {
      const skillMd = join(us.path, "SKILL.md");
      if (!existsSync(skillMd)) continue;

      const info = this.parseSkill(us.name, us.path, skillMd);
      if (info) {
        this.skills.set(us.name, info);
      }
    }
  }

  /** Get full skill detail: metadata + SKILL.md content + file tree. */
  getDetail(name: string): SkillDetail | undefined {
    const skill = this.skills.get(name);
    if (!skill) return undefined;

    const skillMdPath = join(skill.path, "SKILL.md");
    const content = existsSync(skillMdPath) ? readFileSync(skillMdPath, "utf-8") : "";
    const files = this.listFiles(skill.path);

    return { skill, content, files };
  }

  /** Read a file from a skill's directory. Returns content or undefined if not found/outside boundary. */
  getFileContent(name: string, relPath: string): string | undefined {
    const skill = this.skills.get(name);
    if (!skill) return undefined;

    // Guard against path traversal
    const target = join(skill.path, relPath);
    let resolved: string;
    try {
      resolved = realpathSync(target);
    } catch {
      return undefined;
    }

    let realBase: string;
    try {
      realBase = realpathSync(skill.path);
    } catch {
      return undefined;
    }

    if (!resolved.startsWith(realBase + "/") && resolved !== realBase) {
      return undefined;
    }

    try {
      const stat = statSync(resolved);
      if (!stat.isFile()) return undefined;
      // 1MB safety limit
      if (stat.size > 1024 * 1024) return undefined;
      return readFileSync(resolved, "utf-8");
    } catch {
      return undefined;
    }
  }

  // ─── Internal ───

  /** Recursively list files in a skill directory (relative paths). */
  private listFiles(baseDir: string): string[] {
    return listFilesRecursive(baseDir);
  }

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
    return extractDescription(content);
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

// ─── User Skills ───

/** User-created skill metadata. */
export interface UserSkill {
  name: string;
  description: string;
  userId: string;
  builtIn: false;
  createdAt: number; // epoch ms
  /** Total size in bytes (all files). */
  sizeBytes: number;
  /** Host path to the skill directory. */
  path: string;
}

/** Merged skill type: built-in or user-created. */
export type MergedSkill = (SkillInfo & { builtIn: true }) | UserSkill;

/** Validation constraints. */
const SKILL_NAME_RE = /^[a-z][a-z0-9-]{0,63}$/;
const MAX_SKILL_SIZE = 100 * 1024; // 100KB total
const MAX_SKILL_FILES = 50;

export class SkillValidationError extends Error {
  constructor(
    message: string,
    public readonly code: string,
  ) {
    super(message);
    this.name = "SkillValidationError";
  }
}

/**
 * Manages user-created skills on disk.
 *
 * Storage layout:
 *   <baseDir>/<userId>/<skill-name>/
 *     SKILL.md
 *     scripts/...
 *
 * Default baseDir: ~/.config/oppi/skills/
 */
export class UserSkillStore {
  private baseDir: string;

  constructor(baseDir?: string) {
    this.baseDir = baseDir ?? join(homedir(), ".config", "oppi", "skills");
  }

  /** Ensure the base directory exists. */
  init(): void {
    if (!existsSync(this.baseDir)) {
      mkdirSync(this.baseDir, { recursive: true, mode: 0o700 });
    }
  }

  /** List all user skills for a given user. */
  listSkills(userId: string): UserSkill[] {
    const userDir = join(this.baseDir, userId);
    if (!existsSync(userDir)) return [];

    const results: UserSkill[] = [];
    for (const entry of readdirSync(userDir)) {
      const skillDir = join(userDir, entry);
      try {
        if (!statSync(skillDir).isDirectory()) continue;
      } catch {
        continue;
      }

      const skill = this.readSkill(userId, entry, skillDir);
      if (skill) results.push(skill);
    }

    return results;
  }

  /** Get a single user skill by name. Returns null if not found. */
  getSkill(userId: string, name: string): UserSkill | null {
    const skillDir = join(this.baseDir, userId, name);
    if (!existsSync(skillDir)) return null;
    return this.readSkill(userId, name, skillDir);
  }

  /** Get the host path for a user skill (for syncing into containers). */
  getPath(userId: string, name: string): string | null {
    const dir = join(this.baseDir, userId, name);
    return existsSync(dir) ? dir : null;
  }

  /**
   * Save a skill from a source directory (typically a session workspace).
   *
   * Validates:
   * - Name format (lowercase, hyphens, 1-64 chars)
   * - SKILL.md exists in source
   * - Total size under 100KB
   * - Max 50 files
   *
   * @param userId - Owner
   * @param name - Skill name (must match SKILL_NAME_RE)
   * @param sourceDir - Directory to copy from (must contain SKILL.md)
   * @returns The saved skill
   */
  saveSkill(userId: string, name: string, sourceDir: string): UserSkill {
    // Validate name
    if (!SKILL_NAME_RE.test(name)) {
      throw new SkillValidationError(
        `Invalid skill name "${name}" — must match ${SKILL_NAME_RE}`,
        "INVALID_NAME",
      );
    }

    // Validate source exists
    if (!existsSync(sourceDir)) {
      throw new SkillValidationError(
        `Source directory not found: ${sourceDir}`,
        "SOURCE_NOT_FOUND",
      );
    }

    // Validate SKILL.md exists
    const skillMd = join(sourceDir, "SKILL.md");
    if (!existsSync(skillMd)) {
      throw new SkillValidationError(`SKILL.md not found in source directory`, "NO_SKILL_MD");
    }

    // Validate size + file count
    const { totalSize, fileCount } = this.measureDir(sourceDir);
    if (totalSize > MAX_SKILL_SIZE) {
      throw new SkillValidationError(
        `Skill too large: ${(totalSize / 1024).toFixed(1)}KB (max ${MAX_SKILL_SIZE / 1024}KB)`,
        "TOO_LARGE",
      );
    }
    if (fileCount > MAX_SKILL_FILES) {
      throw new SkillValidationError(
        `Too many files: ${fileCount} (max ${MAX_SKILL_FILES})`,
        "TOO_MANY_FILES",
      );
    }

    // Ensure user dir exists
    const userDir = join(this.baseDir, userId);
    if (!existsSync(userDir)) {
      mkdirSync(userDir, { recursive: true, mode: 0o700 });
    }

    // Copy source → destination (overwrite if exists)
    const destDir = join(userDir, name);
    if (existsSync(destDir)) {
      rmSync(destDir, { recursive: true });
    }
    cpSync(sourceDir, destDir, { recursive: true, dereference: true });

    const skill = this.readSkill(userId, name, destDir);
    if (!skill) {
      throw new SkillValidationError(
        `Failed to read saved skill — SKILL.md may be malformed`,
        "READ_FAILED",
      );
    }

    console.log(
      `[skills] Saved user skill "${name}" for ${userId} (${(totalSize / 1024).toFixed(1)}KB, ${fileCount} files)`,
    );
    return skill;
  }

  /** Delete a user skill. Returns true if it existed. */
  deleteSkill(userId: string, name: string): boolean {
    const skillDir = join(this.baseDir, userId, name);
    if (!existsSync(skillDir)) return false;

    rmSync(skillDir, { recursive: true });
    console.log(`[skills] Deleted user skill "${name}" for ${userId}`);
    return true;
  }

  /** List files in a user skill (relative paths). */
  listFiles(userId: string, name: string): string[] {
    const skillDir = join(this.baseDir, userId, name);
    if (!existsSync(skillDir)) return [];
    return listFilesRecursive(skillDir);
  }

  /** Read a file from a user skill. Path-safe. */
  readFile(userId: string, name: string, relPath: string): string | undefined {
    const skillDir = join(this.baseDir, userId, name);
    if (!existsSync(skillDir)) return undefined;

    const target = join(skillDir, relPath);
    let resolved: string;
    try {
      resolved = realpathSync(target);
    } catch {
      return undefined;
    }

    let realBase: string;
    try {
      realBase = realpathSync(skillDir);
    } catch {
      return undefined;
    }

    if (!resolved.startsWith(realBase + "/") && resolved !== realBase) {
      return undefined; // path traversal blocked
    }

    try {
      const stat = statSync(resolved);
      if (!stat.isFile()) return undefined;
      if (stat.size > 1024 * 1024) return undefined; // 1MB safety
      return readFileSync(resolved, "utf-8");
    } catch {
      return undefined;
    }
  }

  // ─── Internal ───

  private readSkill(userId: string, name: string, dir: string): UserSkill | null {
    const skillMd = join(dir, "SKILL.md");
    if (!existsSync(skillMd)) return null;

    const content = readFileSync(skillMd, "utf-8");
    const description = extractDescription(content);
    if (!description) return null;

    const { totalSize } = this.measureDir(dir);
    const dirStat = statSync(dir);

    return {
      name,
      description,
      userId,
      builtIn: false as const,
      createdAt: dirStat.mtimeMs,
      sizeBytes: totalSize,
      path: dir,
    };
  }

  private measureDir(dir: string): { totalSize: number; fileCount: number } {
    let totalSize = 0;
    let fileCount = 0;

    const walk = (d: string) => {
      let entries: string[];
      try {
        entries = readdirSync(d);
      } catch {
        return;
      }
      for (const entry of entries) {
        const full = join(d, entry);
        try {
          const stat = statSync(full);
          if (stat.isDirectory()) {
            walk(full);
          } else if (stat.isFile()) {
            totalSize += stat.size;
            fileCount++;
          }
        } catch {
          /* skip */
        }
      }
    };

    walk(dir);
    return { totalSize, fileCount };
  }
}

// ─── Shared Helpers ───

/** Extract description from SKILL.md YAML frontmatter. */
function extractDescription(content: string): string {
  const fmMatch = content.match(/^---\s*\n([\s\S]*?)\n---/);
  if (!fmMatch) return "";
  const frontmatter = fmMatch[1];
  const descMatch = frontmatter.match(/^description:\s*"?([^"\n]+)"?\s*$/m);
  if (!descMatch) return "";
  return descMatch[1].trim();
}

/** Recursively list files, skipping junk directories and binary extensions. */
function listFilesRecursive(baseDir: string, prefix = ""): string[] {
  const SKIP_DIRS = new Set([
    "__pycache__",
    "node_modules",
    ".git",
    ".venv",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    "__pypackages__",
  ]);
  const SKIP_EXTS = new Set([".pyc", ".pyo", ".o", ".so", ".dylib"]);
  const results: string[] = [];
  const dir = prefix ? join(baseDir, prefix) : baseDir;

  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    return results;
  }

  for (const entry of entries.sort()) {
    const rel = prefix ? `${prefix}/${entry}` : entry;
    const full = join(dir, entry);
    try {
      const stat = statSync(full);
      if (stat.isDirectory()) {
        if (!SKIP_DIRS.has(entry)) {
          results.push(...listFilesRecursive(baseDir, rel));
        }
      } else if (stat.isFile()) {
        const ext = entry.substring(entry.lastIndexOf("."));
        if (!SKIP_EXTS.has(ext)) results.push(rel);
      }
    } catch {
      /* skip */
    }
  }

  return results;
}
