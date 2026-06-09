/**
 * Skill registry — discovers and catalogs skills from Pi-owned locations.
 *
 * Default skills: discovered from ~/.pi/agent/skills.
 * Bundled skills: discovered from server/skills when present.
 * Package skills: discovered from pi packages installed via `pi install`
 * and settings-declared skill paths through the Pi SDK.
 */

import {
  existsSync,
  readdirSync,
  readFileSync,
  realpathSync,
  statSync,
  watch,
  type FSWatcher,
} from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { EventEmitter } from "node:events";
import {
  DefaultPackageManager,
  loadSkills,
  SettingsManager,
  type Skill,
} from "@earendil-works/pi-coding-agent";
import { createLogger } from "./logger.js";

// ─── Types ───

export interface SkillInfo {
  /** Skill name (directory name, e.g. "searxng"). */
  name: string;
  /** Human-readable description from SKILL.md frontmatter. */
  description: string;
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

/** Map SDK Skill to our SkillInfo. */
function sdkSkillToInfo(skill: Skill): SkillInfo {
  return {
    name: skill.name,
    description: skill.description,
    path: skill.baseDir,
  };
}

// ─── Skill Registry ───

const log = createLogger({ base: { component: "skills" } });
const HOST_AGENT_DIR = join(homedir(), ".pi", "agent");
const HOST_SKILLS_DIR = join(HOST_AGENT_DIR, "skills");
const SKILLS_SDK_CWD = process.cwd();

/** Emitted when the skill catalog changes after a re-scan. */
export interface SkillsChangedEvent {
  added: string[];
  removed: string[];
  modified: string[];
}

export class SkillRegistry extends EventEmitter {
  private skills: Map<string, SkillInfo> = new Map();
  private scanDirs: string[];
  /** Skill paths resolved from pi settings packages + skills arrays. */
  private packageSkillPaths: string[] = [];
  private packageSkillsResolved = false;
  private watchers: FSWatcher[] = [];
  private debounceTimer: ReturnType<typeof setTimeout> | null = null;
  private debounceMs: number;

  constructor(extraDirs?: string[], opts?: { debounceMs?: number }) {
    super();
    this.scanDirs = [HOST_SKILLS_DIR, ...(extraDirs || [])];
    this.debounceMs = opts?.debounceMs ?? 500;
  }

  /**
   * Resolve skill paths from pi settings (packages + skills arrays).
   *
   * Uses the SDK's SettingsManager + DefaultPackageManager to discover
   * skills from `pi install`-ed packages and settings-declared skill
   * directories — the same logic pi uses at startup.
   *
   * Call once before scan(). Skipped packages that aren't installed
   * yet (no auto-install in server context).
   */
  async resolvePackageSkills(): Promise<void> {
    if (this.packageSkillsResolved) return;
    this.packageSkillsResolved = true;

    try {
      const settingsManager = SettingsManager.create(SKILLS_SDK_CWD, HOST_AGENT_DIR);
      const packageManager = new DefaultPackageManager({
        cwd: SKILLS_SDK_CWD,
        agentDir: HOST_AGENT_DIR,
        settingsManager,
      });

      // Skip missing packages — don't auto-install in server context
      const resolved = await packageManager.resolve(async () => "skip");

      // Collect enabled skill paths, excluding those already under scanDirs
      // (those are loaded by scan() directly to avoid double-loading).
      const paths = resolved.skills
        .filter((r) => r.enabled)
        .map((r) => r.path)
        .filter((p) => !this.scanDirs.some((dir) => p.startsWith(dir + "/")));

      if (paths.length > 0) {
        this.packageSkillPaths = paths;
        log.info("skills.package_paths_resolved", {
          count: paths.length,
        });
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      log.warn("skills.package_paths_resolve.failed", {
        error: message,
      });
    }
  }

  /**
   * Scan host skill directories and build the registry.
   * Delegates discovery to the pi SDK loadSkills(), then maps results
   * to our SkillInfo shape. Idempotent — safe to call anytime.
   * Emits "skills:changed" if the catalog changed since the last scan.
   */
  scan(): SkillsChangedEvent {
    const prevNames = new Set(this.skills.keys());
    const prevDescriptions = new Map(
      Array.from(this.skills.entries()).map(([k, v]) => [k, v.description]),
    );

    this.skills.clear();

    // Use SDK loadSkills for each scan directory
    for (const dir of this.scanDirs) {
      if (!existsSync(dir)) continue;

      try {
        const result = loadSkills({
          cwd: SKILLS_SDK_CWD,
          agentDir: HOST_AGENT_DIR,
          skillPaths: [dir],
          includeDefaults: false,
        });

        for (const skill of result.skills) {
          // First dir wins on name collision (same as before)
          if (this.skills.has(skill.name)) continue;
          this.skills.set(skill.name, sdkSkillToInfo(skill));
        }
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        log.warn("skills.scan_directory.failed", {
          dir,
          error: message,
        });
      }
    }

    // Load skills resolved from pi packages/settings.
    // These are individual file paths (SKILL.md or top-level .md) from
    // DefaultPackageManager.resolve(). Feed them to loadSkills which
    // handles both files and directories, validates frontmatter, etc.
    if (this.packageSkillPaths.length > 0) {
      try {
        const result = loadSkills({
          cwd: SKILLS_SDK_CWD,
          agentDir: HOST_AGENT_DIR,
          skillPaths: this.packageSkillPaths,
          includeDefaults: false,
        });
        for (const skill of result.skills) {
          if (this.skills.has(skill.name)) continue;
          this.skills.set(skill.name, sdkSkillToInfo(skill));
        }
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        log.warn("skills.package_skills_load.failed", {
          error: message,
        });
      }
    }

    // Compute diff
    const currentNames = new Set(this.skills.keys());
    const added = [...currentNames].filter((n) => !prevNames.has(n));
    const removed = [...prevNames].filter((n) => !currentNames.has(n));
    const modified = [...currentNames].filter((n) => {
      if (!prevNames.has(n)) return false; // new, not modified
      return prevDescriptions.get(n) !== this.skills.get(n)?.description;
    });

    const event: SkillsChangedEvent = { added, removed, modified };

    if (added.length || removed.length || modified.length) {
      log.info("skills.catalog_changed", {
        added: added.length,
        removed: removed.length,
        modified: modified.length,
        total: this.skills.size,
      });
      this.emit("skills:changed", event);
    }

    return event;
  }

  /**
   * Start watching skill directories for changes.
   * Debounces rapid changes and re-scans automatically.
   */
  watch(): void {
    this.stopWatching();

    for (const dir of this.scanDirs) {
      if (!existsSync(dir)) continue;

      try {
        const watcher = watch(dir, { recursive: true }, () => {
          this.debouncedRescan();
        });
        this.watchers.push(watcher);
      } catch (err) {
        log.warn("skills.watch_directory.failed", {
          dir,
          error: String(err),
        });
      }
    }

    if (this.watchers.length > 0) {
      log.info("skills.watch.started", {
        watcherCount: this.watchers.length,
      });
    }
  }

  /** Stop all file watchers. */
  stopWatching(): void {
    for (const w of this.watchers) {
      try {
        w.close();
      } catch {
        /* ignore */
      }
    }
    this.watchers = [];
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
  }

  private debouncedRescan(): void {
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = null;
      this.scan();
    }, this.debounceMs);
  }

  /** Get all available skills. */
  list(): SkillInfo[] {
    return Array.from(this.skills.values());
  }

  /** Get a single skill by name. */
  get(name: string): SkillInfo | undefined {
    return this.skills.get(name);
  }

  /** Get the host path for a skill. */
  getPath(name: string): string | undefined {
    return this.skills.get(name)?.path;
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
}

// ─── Shared Helpers ───

/** Extract an arbitrary field from SKILL.md YAML frontmatter. */
export function extractFrontmatterField(content: string, field: string): string | undefined {
  const fmMatch = content.match(/^---\s*\n([\s\S]*?)\n---/);
  if (!fmMatch) return undefined;
  const re = new RegExp(`^${field}:\\s*"?([^"\\n]+)"?\\s*$`, "m");
  const match = fmMatch[1].match(re);
  return match ? match[1].trim() : undefined;
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
