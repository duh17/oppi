/**
 * Host filesystem discovery for workspace creation.
 *
 * Scans directories on the host Mac to help the iOS client build a
 * workspace picker. Returns project metadata (git remote, language,
 * AGENTS.md presence) without requiring the user to type paths.
 */

import { mkdirSync, readdirSync, existsSync, realpathSync, statSync, type Dirent } from "node:fs";
import { dirname, join, basename, resolve } from "node:path";
import { homedir } from "node:os";
import { execSync } from "node:child_process";

// ─── Types ───

export interface HostPathStatus {
  /** Original display/input path. */
  path: string;
  /** Absolute path after ~ expansion. */
  resolvedPath: string;
  exists: boolean;
  isDirectory: boolean;
  isFile: boolean;
  issue?: "missing" | "not_directory" | "inaccessible";
  message?: string;
}

export interface HostPathCompletion {
  /** Completed display path, using ~ when under the user's home directory. */
  path: string;
  name: string;
}

export interface HostPathCreateResult {
  created: boolean;
  status: HostPathStatus;
}

export class HostPathCreateError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "HostPathCreateError";
  }
}

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

// ─── Path helpers ───

const DEFAULT_WORKSPACE_CREATE_ROOTS = [
  "~/workspace",
  "~/projects",
  "~/src",
  "~/code",
  "~/Developer",
  "~/sandbox",
];

const DISALLOWED_CREATE_SEGMENTS = new Set(["", ".", ".."]);

function compressHome(path: string): string {
  const home = homedir();
  return path === home || path.startsWith(home + "/") ? path.replace(home, "~") : path;
}

export function resolveHostPath(rawPath: string): string {
  const trimmed = rawPath.trim();
  const expanded =
    trimmed === "~" || trimmed.startsWith("~/")
      ? trimmed.replace(/^~(?=\/|$)/, homedir())
      : trimmed;

  return resolve(expanded);
}

export function getHostPathStatus(rawPath: string): HostPathStatus {
  const path = rawPath.trim();
  const resolvedPath = resolveHostPath(path);

  try {
    const info = statSync(resolvedPath);
    if (!info.isDirectory()) {
      return {
        path,
        resolvedPath,
        exists: true,
        isDirectory: false,
        isFile: info.isFile(),
        issue: "not_directory",
        message: `Path is not a directory: ${resolvedPath}`,
      };
    }

    return { path, resolvedPath, exists: true, isDirectory: true, isFile: false };
  } catch (err: unknown) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code === "ENOENT" || code === "ENOTDIR") {
      return {
        path,
        resolvedPath,
        exists: false,
        isDirectory: false,
        isFile: false,
        issue: "missing",
        message: `Path does not exist: ${resolvedPath}`,
      };
    }

    const reason = err instanceof Error ? err.message : "unknown error";
    return {
      path,
      resolvedPath,
      exists: false,
      isDirectory: false,
      isFile: false,
      issue: "inaccessible",
      message: `Path is not accessible: ${resolvedPath} (${reason})`,
    };
  }
}

export function hostMountValidationError(hostMount: unknown): string | undefined {
  if (hostMount === undefined || hostMount === null) {
    return undefined;
  }

  if (typeof hostMount !== "string") {
    return "hostMount must be a string";
  }

  const trimmed = hostMount.trim();
  if (!trimmed) {
    return undefined;
  }

  const status = getHostPathStatus(trimmed);
  if (!status.issue) {
    return undefined;
  }

  switch (status.issue) {
    case "missing":
      return `Host working directory does not exist: ${status.resolvedPath}. Choose an existing folder, clear Host Working Directory for a blank workspace, or create the folder on the server.`;
    case "not_directory":
      return `Host working directory is not a directory: ${status.resolvedPath}. Choose an existing folder or clear Host Working Directory for a blank workspace.`;
    case "inaccessible":
      return `Host working directory is not accessible: ${status.resolvedPath}. Choose a different folder or fix permissions on the server.`;
  }
}

function pathWithin(parent: string, child: string): boolean {
  return child === parent || child.startsWith(parent + "/");
}

function existingCreateRoots(): string[] {
  return DEFAULT_WORKSPACE_CREATE_ROOTS.map(resolveHostPath).filter((root) => {
    try {
      return statSync(root).isDirectory();
    } catch {
      return false;
    }
  });
}

function allowedCreateRootRealpaths(): string[] {
  return existingCreateRoots().flatMap((root) => {
    try {
      return [realpathSync(root)];
    } catch {
      return [];
    }
  });
}

function isWithinAllowedCreateRoot(realpath: string): boolean {
  return allowedCreateRootRealpaths().some((root) => pathWithin(root, realpath));
}

function assertSafeCreateTarget(resolvedPath: string): void {
  const name = basename(resolvedPath);
  if (DISALLOWED_CREATE_SEGMENTS.has(name) || name.startsWith(".")) {
    throw new HostPathCreateError(400, "Choose a visible folder name to create.");
  }

  const parent = dirname(resolvedPath);
  let parentRealpath: string;
  try {
    const parentStats = statSync(parent);
    if (!parentStats.isDirectory()) {
      throw new HostPathCreateError(400, "Parent path is not a directory.");
    }
    parentRealpath = realpathSync(parent);
  } catch (err: unknown) {
    if (err instanceof HostPathCreateError) {
      throw err;
    }
    throw new HostPathCreateError(400, "Parent directory must already exist.");
  }

  const targetRealpath = join(parentRealpath, name);
  if (targetRealpath === parentRealpath || !isWithinAllowedCreateRoot(targetRealpath)) {
    throw new HostPathCreateError(
      403,
      "For safety, folders can only be created under ~/workspace, ~/projects, ~/src, ~/code, ~/Developer, or ~/sandbox.",
    );
  }
}

export function createHostWorkspaceDirectory(rawPath: string): HostPathCreateResult {
  const path = rawPath.trim();
  if (!path) {
    throw new HostPathCreateError(400, "path required");
  }

  const resolvedPath = resolveHostPath(path);
  const currentStatus = getHostPathStatus(path);
  if (currentStatus.isDirectory) {
    return { created: false, status: currentStatus };
  }
  if (currentStatus.issue !== "missing") {
    throw new HostPathCreateError(400, currentStatus.message ?? "Path cannot be created.");
  }

  assertSafeCreateTarget(resolvedPath);
  try {
    mkdirSync(resolvedPath, { mode: 0o755 });
  } catch (err: unknown) {
    throw new HostPathCreateError(
      500,
      err instanceof Error ? err.message : "Failed to create directory.",
    );
  }

  return { created: true, status: getHostPathStatus(path) };
}

export function completeHostPath(prefix: string, limit = 20): HostPathCompletion[] {
  const trimmed = prefix.trim();
  if (!trimmed) {
    return [];
  }

  const expandedPrefix = resolveHostPath(trimmed);
  const parent = trimmed.endsWith("/") ? expandedPrefix : dirname(expandedPrefix);
  const partial = trimmed.endsWith("/") ? "" : basename(expandedPrefix).toLowerCase();
  const showHidden = partial.startsWith(".");

  let entries: Dirent[];
  try {
    const parentRealpath = realpathSync(parent);
    const homeRealpath = realpathSync(homedir());
    entries = readdirSync(parent, { withFileTypes: true });
    if (parentRealpath === homeRealpath) {
      const allowedRootNames = new Set(
        DEFAULT_WORKSPACE_CREATE_ROOTS.map((root) => basename(root)),
      );
      entries = entries.filter((entry) => allowedRootNames.has(entry.name));
    } else if (!isWithinAllowedCreateRoot(parentRealpath)) {
      return [];
    }
  } catch {
    return [];
  }

  return entries
    .filter((entry) => entry.isDirectory())
    .filter((entry) => showHidden || !entry.name.startsWith("."))
    .filter((entry) => entry.name.toLowerCase().startsWith(partial))
    .sort((a, b) => a.name.localeCompare(b.name))
    .slice(0, Math.max(1, Math.min(limit, 50)))
    .map((entry) => {
      const completed = join(parent, entry.name);
      return { path: compressHome(completed), name: entry.name };
    });
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
