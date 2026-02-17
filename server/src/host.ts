/**
 * Host filesystem discovery for workspace creation.
 *
 * Scans directories on the host Mac to help the iOS client build a
 * workspace picker. Returns project metadata (git remote, language,
 * AGENTS.md presence) without requiring the user to type paths.
 */

import { readdirSync, existsSync, statSync } from "node:fs";
import { join, basename } from "node:path";
import { homedir } from "node:os";
import { execSync } from "node:child_process";

// ─── Types ───

export interface HostDirectory {
  /** Absolute path (with ~ prefix for display) */
  path: string;
  /** Directory name */
  name: string;
  /** Has .git directory */
  isGitRepo: boolean;
  /** Primary git remote URL (origin), if any */
  gitRemote?: string;
  /** Has AGENTS.md (pi/Claude Code project config) */
  hasAgentsMd: boolean;
  /** Detected project type based on manifest files */
  projectType?: string;
  /** Primary language hint */
  language?: string;
}

// ─── Manifest detection ───

const MANIFESTS: Array<{ file: string; type: string; language: string }> = [
  { file: "package.json", type: "node", language: "TypeScript" },
  { file: "Cargo.toml", type: "rust", language: "Rust" },
  { file: "pyproject.toml", type: "python", language: "Python" },
  { file: "go.mod", type: "go", language: "Go" },
  { file: "Gemfile", type: "ruby", language: "Ruby" },
  { file: "build.gradle", type: "gradle", language: "Java" },
  { file: "pom.xml", type: "maven", language: "Java" },
  { file: "Package.swift", type: "swift", language: "Swift" },
  { file: "project.yml", type: "xcodegen", language: "Swift" },
  { file: "mix.exs", type: "elixir", language: "Elixir" },
  { file: "Makefile", type: "make", language: "" },
];

// Refine language from package.json if TypeScript config exists
function refineLanguage(dir: string, base: string): string {
  if (base === "TypeScript" && !existsSync(join(dir, "tsconfig.json"))) {
    return "JavaScript";
  }
  return base;
}

// ─── Git helpers ───

function getGitRemote(dir: string): string | undefined {
  try {
    const raw = execSync("git remote get-url origin", {
      cwd: dir,
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 2000,
    })
      .toString()
      .trim();
    // Normalize: git@github.com:user/repo.git → github.com/user/repo
    if (raw.startsWith("git@")) {
      return raw
        .replace(/^git@/, "")
        .replace(":", "/")
        .replace(/\.git$/, "");
    }
    try {
      const url = new URL(raw);
      return url.host + url.pathname.replace(/\.git$/, "");
    } catch {
      return raw;
    }
  } catch {
    return undefined;
  }
}

// ─── Scanner ───

/**
 * Scan a directory for project subdirectories.
 *
 * Returns immediate children that look like projects (have .git, a
 * manifest file, or AGENTS.md). Skips hidden directories and common
 * non-project entries (node_modules, .Trash, Library, etc.).
 */
export function scanDirectories(root: string): HostDirectory[] {
  const resolved = root.replace(/^~/, homedir());
  if (!existsSync(resolved)) return [];

  const SKIP = new Set([
    "node_modules",
    ".Trash",
    "Library",
    "Applications",
    ".cache",
    ".config",
    ".local",
    ".npm",
    ".cargo",
    ".rustup",
    ".pyenv",
    ".nvm",
  ]);

  const results: HostDirectory[] = [];

  let entries: string[];
  try {
    entries = readdirSync(resolved);
  } catch {
    return [];
  }

  for (const entry of entries) {
    if (entry.startsWith(".") || SKIP.has(entry)) continue;

    const fullPath = join(resolved, entry);
    try {
      if (!statSync(fullPath).isDirectory()) continue;
    } catch {
      continue;
    }

    const isGitRepo = existsSync(join(fullPath, ".git"));
    const hasAgentsMd = existsSync(join(fullPath, "AGENTS.md"));

    // Detect project type from manifest files
    let projectType: string | undefined;
    let language: string | undefined;
    for (const m of MANIFESTS) {
      if (existsSync(join(fullPath, m.file))) {
        projectType = m.type;
        language = m.language ? refineLanguage(fullPath, m.language) : undefined;
        break;
      }
    }

    // Only include directories that look like projects
    if (!isGitRepo && !hasAgentsMd && !projectType) continue;

    const displayPath = fullPath.replace(homedir(), "~");

    results.push({
      path: displayPath,
      name: basename(fullPath),
      isGitRepo,
      gitRemote: isGitRepo ? getGitRemote(fullPath) : undefined,
      hasAgentsMd,
      projectType,
      language,
    });
  }

  return results.sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * Scan multiple roots and merge results.
 *
 * Default roots: ~/workspace, ~/projects, ~/src, ~/code, ~/Developer
 */
export function discoverProjects(roots?: string[]): HostDirectory[] {
  const defaultRoots = ["~/workspace", "~/projects", "~/src", "~/code", "~/Developer"];
  const scanRoots = roots ?? defaultRoots;
  const seen = new Set<string>();
  const results: HostDirectory[] = [];

  for (const root of scanRoots) {
    for (const dir of scanDirectories(root)) {
      if (!seen.has(dir.path)) {
        seen.add(dir.path);
        results.push(dir);
      }
    }
  }

  return results.sort((a, b) => a.name.localeCompare(b.name));
}
