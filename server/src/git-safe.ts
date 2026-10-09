/**
 * The one place the host server runs git.
 *
 * Sandbox workspace folders are mounted writable into the Gondolin VM and
 * `.git` is not shadowed, so code inside the VM controls the repository's
 * config, `info/attributes`, hooks, and even whether `.git` is a directory, a
 * gitfile, or a symlink. Git runs repository-controlled programs for many
 * ordinary reads (`core.fsmonitor`, `filter.<name>.clean` during status/diff,
 * `diff.<name>.textconv`, `diff.external`, hooks on ref updates). A denylist of
 * config keys cannot cover named drivers (`filter.<anything>`), and the
 * repository can rewrite those files at any moment, so a check-then-run guard is
 * racy too.
 *
 * Trust therefore picks one of two execution shapes:
 *
 * - `host`: `execFile("git", args, { cwd, ...options })`, unchanged. The owner's
 *   own repositories rely on their hooks and config.
 * - `sandbox`: git runs against a host-owned shadow git dir whose `config`,
 *   `info/`, and `HEAD` the host writes. Only data (objects, refs, index,
 *   reflogs, `info/exclude`) is linked from the mount. Repository config and
 *   attributes are never read, so there is nothing to race. Working tree
 *   `.gitattributes` is neutralised with `GIT_ATTR_SOURCE`. Only read-only
 *   subcommands run: a writing command would write through the linked object
 *   store and refs into whatever the VM redirected them to. Worktrees
 *   (`git worktree`, `merge-tree`) therefore do not exist for sandbox workspaces.
 *
 * Sandbox trust first requires the repository to be confined to the mount:
 * `.git` must be a real directory, or a gitfile whose resolved gitdir stays
 * inside the mount's real path, with no `commondir` redirect and every object
 * alternate inside the mount. Anything else, including a redirect file that
 * cannot be read in full, is treated as not a git repo.
 */

import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";

import { isPathWithinRoot, resolveHomePath } from "./git-utils.js";
import type { Workspace } from "./types.js";

// ─── Trust ───

/** Who controls the repository a git command will read. */
export type GitTrust =
  | { readonly kind: "host" }
  | {
      readonly kind: "sandbox";
      /** Workspace mount: the only tree a sandbox repository may live in. */
      readonly root: string;
    };

export const HOST_GIT_TRUST: GitTrust = { kind: "host" };

/**
 * Trust for git commands that target a workspace's mount or any worktree of it.
 * Derive it from the workspace record, not from a path: quick actions and
 * worktree callers substitute `hostMount` with a worktree checkout path while
 * the workspace stays sandboxed.
 */
export function gitTrustForWorkspace(
  workspace: Pick<Workspace, "runtime" | "hostMount">,
): GitTrust {
  if (workspace.runtime !== "sandbox") return HOST_GIT_TRUST;
  return { kind: "sandbox", root: resolve(resolveHomePath(workspace.hostMount)) };
}

export interface GitExecOptions {
  timeout?: number;
  maxBuffer?: number;
  encoding?: BufferEncoding;
  windowsHide?: boolean;
}

export interface GitExecResult {
  /** Null on exit status 0. Shape matches `execFile`'s callback error. */
  error: (Error & { code?: unknown; status?: unknown }) | null;
  stdout: string | Buffer;
  stderr: string | Buffer;
}

/** Git was not run because the sandbox repository is not confined to its mount. */
export class SandboxGitRefusedError extends Error {
  readonly code = 128;
  constructor(reason: string) {
    super(`git refused for sandbox workspace: ${reason}`);
    this.name = "SandboxGitRefusedError";
  }
}

/**
 * Whether `dir` is a git repository the host may run git against. Host trust
 * keeps the original `<dir>/.git` existence check; sandbox trust requires a
 * repository confined to the mount.
 */
export function isGitRepository(trust: GitTrust, dir: string): boolean {
  if (trust.kind === "host") return existsSync(join(dir, ".git"));
  return resolveSandboxRepo(trust, dir) !== null;
}

/** Run git for `trust`. Never throws: failures come back in `error`. */
export async function execGit(
  trust: GitTrust,
  cwd: string,
  args: readonly string[],
  options: GitExecOptions = {},
): Promise<GitExecResult> {
  if (trust.kind === "host") {
    return runGit(["git"], args, { cwd, ...options });
  }

  if (!isSandboxReadOnlyCommand(args)) {
    return refused(`\`git ${args.join(" ")}\` is not a read-only command`);
  }

  let plan: SandboxPlan | null;
  try {
    plan = await planSandboxGit(trust, cwd);
  } catch (error) {
    if (error instanceof SandboxGitRefusedError) return { error, stdout: "", stderr: "" };
    return refused(error instanceof Error ? error.message : "unexpected failure");
  }
  if (!plan) return refused("repository is not confined to the workspace mount");

  return runGit(["git", ...SANDBOX_GLOBAL_ARGS], args, {
    ...options,
    cwd: plan.cwd,
    env: plan.env,
  });
}

function refused(reason: string): GitExecResult {
  return { error: new SandboxGitRefusedError(reason), stdout: "", stderr: "" };
}

function runGit(
  [file, ...prefix]: string[],
  args: readonly string[],
  options: Parameters<typeof execFile>[2],
): Promise<GitExecResult> {
  return new Promise((resolvePromise) => {
    execFile(file, [...prefix, ...args], options, (error, stdout, stderr) => {
      resolvePromise({ error, stdout, stderr });
    });
  });
}

// ─── Sandbox command shape ───

const SANDBOX_READ_SUBCOMMANDS = new Set([
  "status",
  "rev-parse",
  "log",
  "rev-list",
  "diff",
  "diff-tree",
  "show",
]);

/**
 * Sandbox git may only read. The shadow links `objects`, `refs`, and `index`
 * into the mount, and the VM can replace any child of those with a symlink, so a
 * command that writes a loose object, ref, or index would write where the VM
 * points it. `status` stays read-only through `--no-optional-locks`.
 */
function isSandboxReadOnlyCommand(args: readonly string[]): boolean {
  if (args.some((arg) => arg === "--output" || arg.startsWith("--output="))) return false;
  const index = args.findIndex((arg) => !arg.startsWith("-"));
  if (index < 0) return false;
  const subcommand = args[index];
  const rest = args.slice(index + 1);
  if (subcommand === "branch") return rest.length === 1 && rest[0] === "--show-current";
  if (subcommand === "stash") return rest.length === 1 && rest[0] === "list";
  return subcommand !== undefined && SANDBOX_READ_SUBCOMMANDS.has(subcommand);
}

/**
 * The shadow git dir carries none of the repository's config, so these are
 * defence in depth for subprocesses git starts (submodules read their own).
 */
const SANDBOX_CONFIG_OVERRIDES: readonly string[] = [
  "core.fsmonitor=false",
  "core.hooksPath=/dev/null",
  "core.attributesFile=/dev/null",
  "core.pager=cat",
  "core.sshCommand=false",
  "core.askPass=",
  "credential.helper=",
  "protocol.allow=never",
  "gpg.program=false",
  "gpg.ssh.program=false",
  "gpg.x509.program=false",
  "gc.auto=0",
  "maintenance.auto=false",
  // A submodule is a repository the sandbox also controls; git would run status
  // inside it with that repository's own config and attributes.
  "diff.ignoreSubmodules=all",
  "status.submoduleSummary=false",
  "submodule.recurse=false",
];

const SANDBOX_GLOBAL_ARGS: readonly string[] = [
  "--no-pager",
  "--no-optional-locks",
  ...SANDBOX_CONFIG_OVERRIDES.flatMap((entry) => ["-c", entry]),
];

const EMPTY_TREE_SHA1 = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
const EMPTY_TREE_SHA256 = "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321";

/** Pass through only what git needs to find itself and render paths. */
function sandboxBaseEnv(): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value === undefined) continue;
    // Drops GIT_DIR, GIT_EXTERNAL_DIFF, GIT_SSH*, GIT_CONFIG_PARAMETERS, etc.
    if (key.startsWith("GIT_") && key !== "GIT_EXEC_PATH") continue;
    env[key] = value;
  }
  env.GIT_CONFIG_NOSYSTEM = "1";
  env.GIT_CONFIG_GLOBAL = "/dev/null";
  env.GIT_ATTR_NOSYSTEM = "1";
  env.GIT_OPTIONAL_LOCKS = "0";
  env.GIT_TERMINAL_PROMPT = "0";
  env.GIT_NO_LAZY_FETCH = "1";
  env.GIT_PAGER = "cat";
  return env;
}

interface SandboxPlan {
  cwd: string;
  env: NodeJS.ProcessEnv;
}

async function planSandboxGit(
  trust: Extract<GitTrust, { kind: "sandbox" }>,
  cwd: string,
): Promise<SandboxPlan | null> {
  const repo = resolveSandboxRepo(trust, cwd);
  if (!repo) return null;

  const env = sandboxBaseEnv();
  env.GIT_WORK_TREE = repo.workTree;
  // Rooted at the mount's parent, discovery cannot climb into host repositories.
  env.GIT_CEILING_DIRECTORIES = dirname(repo.workTree);

  const shadow = await prepareShadowGitDir(repo);
  env.GIT_DIR = shadow.dir;
  env.GIT_ATTR_SOURCE = shadow.objectFormat === "sha256" ? EMPTY_TREE_SHA256 : EMPTY_TREE_SHA1;
  return { cwd: repo.cwd, env };
}

// ─── Confinement ───

interface SandboxRepo {
  /** Real path of the mount root. */
  workTree: string;
  /** Real cwd inside `workTree`. */
  cwd: string;
  /** Real git dir, inside the mount. */
  gitDir: string;
}

function lstatOrNull(path: string): ReturnType<typeof lstatSync> | null {
  try {
    return lstatSync(path);
  } catch {
    return null;
  }
}

function realpathOrNull(path: string): string | null {
  try {
    return realpathSync(path);
  } catch {
    return null;
  }
}

function readSmallFile(path: string, maxBytes = 64 * 1024): string | null {
  try {
    const content = readFileSync(path, "utf8");
    return content.length > maxBytes ? null : content;
  } catch {
    return null;
  }
}

/** The git dir `<dir>/.git` names, if it stays inside `mountRoot`. */
function confinedGitDir(dir: string, mountRoot: string): string | null {
  const dotGit = join(dir, ".git");
  const stat = lstatOrNull(dotGit);
  if (!stat) return null;

  if (stat.isSymbolicLink()) return null;
  if (stat.isDirectory()) {
    const real = realpathOrNull(dotGit);
    return real && isPathWithinRoot(real, mountRoot) ? real : null;
  }
  if (!stat.isFile()) return null;

  const match = /^gitdir:\s*(.+?)\s*$/m.exec(readSmallFile(dotGit) ?? "");
  if (!match?.[1]) return null;
  const real = realpathOrNull(isAbsolute(match[1]) ? match[1] : resolve(dir, match[1]));
  return real && isPathWithinRoot(real, mountRoot) ? real : null;
}

/**
 * Every path git follows out of the git dir for data stays inside the mount, and
 * no redirect file can send it elsewhere. A redirect that is present but cannot
 * be read in full is a refusal: "unreadable" must never mean "absent".
 */
function gitDirConfined(gitDir: string, mountRoot: string): boolean {
  // A linked-worktree git dir points at a shared common dir; sandbox mounts have none.
  if (lstatOrNull(join(gitDir, "commondir"))) return false;

  for (const name of ["objects", "refs", "packed-refs", "logs", "reftable", "shallow"]) {
    const path = join(gitDir, name);
    if (!lstatOrNull(path)) continue;
    const real = realpathOrNull(path);
    if (!real || !isPathWithinRoot(real, mountRoot)) return false;
  }

  const alternatesPath = join(gitDir, "objects", "info", "alternates");
  const alternatesStat = lstatOrNull(alternatesPath);
  if (alternatesStat) {
    if (!alternatesStat.isFile()) return false;
    const alternates = readSmallFile(alternatesPath);
    if (alternates === null) return false;
    for (const line of alternates.split("\n")) {
      const entry = line.trim();
      if (!entry || entry.startsWith("#")) continue;
      const real = realpathOrNull(isAbsolute(entry) ? entry : resolve(gitDir, "objects", entry));
      if (!real || !isPathWithinRoot(real, mountRoot)) return false;
    }
  }
  return true;
}

/** Resolve the repository a sandbox git command may touch: the mount's own, or null. */
function resolveSandboxRepo(
  trust: Extract<GitTrust, { kind: "sandbox" }>,
  cwd: string,
): SandboxRepo | null {
  const mountRoot = realpathOrNull(trust.root);
  const realCwd = realpathOrNull(resolveHomePath(cwd));
  if (!mountRoot || !realCwd || !isPathWithinRoot(realCwd, mountRoot)) return null;

  const gitDir = confinedGitDir(mountRoot, mountRoot);
  if (!gitDir || !gitDirConfined(gitDir, mountRoot)) return null;
  return { workTree: mountRoot, cwd: realCwd, gitDir };
}

// ─── Isolated mode: shadow git dir ───

const SHADOW_CONFIG_KEYS = new Set([
  "core.repositoryformatversion",
  "core.filemode",
  "core.ignorecase",
  "core.precomposeunicode",
  "core.autocrlf",
  "core.eol",
  "core.safecrlf",
  "core.quotepath",
  "core.trustctime",
  "core.checkstat",
  "extensions.objectformat",
]);

const SAFE_VALUE = /^[A-Za-z0-9_./@+*:%-]*$/;
const SAFE_SUBSECTION = /^[A-Za-z0-9_./@+-]+$/;

/**
 * Keep only data keys from a repository's config lines (`key\nvalue\0`): core
 * format/line-ending keys, the object format, and the tracking keys `@{upstream}`
 * needs. Everything else, including every `filter.*`, `diff.*`, `remote.*.url`,
 * and `include.*`, is dropped. Values are restricted so they cannot break out of
 * the generated config line.
 */
function shadowConfigText(listing: string): string {
  const core: string[] = [];
  const objectFormat: string[] = [];
  const other: string[] = [];
  let formatVersion = "0";

  for (const record of listing.split("\0")) {
    const newline = record.indexOf("\n");
    if (newline < 0) continue;
    const key = record.slice(0, newline);
    const value = record.slice(newline + 1);
    if (!SAFE_VALUE.test(value)) continue;

    if (SHADOW_CONFIG_KEYS.has(key)) {
      if (key === "core.repositoryformatversion") {
        if (value === "0" || value === "1") formatVersion = value;
      } else if (key === "extensions.objectformat") {
        if (value === "sha1" || value === "sha256") objectFormat.push(`\tobjectformat = ${value}`);
      } else {
        core.push(`\t${key.slice("core.".length)} = ${value}`);
      }
      continue;
    }

    const parts = /^(branch|remote)\.(.+)\.(remote|merge|fetch)$/.exec(key);
    if (!parts?.[1] || !parts[2] || !parts[3] || !SAFE_SUBSECTION.test(parts[2])) continue;
    const allowed =
      (parts[1] === "branch" && (parts[3] === "remote" || parts[3] === "merge")) ||
      (parts[1] === "remote" && parts[3] === "fetch");
    if (allowed) other.push(`[${parts[1]} "${parts[2]}"]\n\t${parts[3]} = ${value}`);
  }

  const lines = [
    "[core]",
    `\trepositoryformatversion = ${formatVersion}`,
    "\tbare = false",
    // Never the repository's value: symlinks = false makes git read through links.
    "\tsymlinks = true",
    ...core,
  ];
  if (objectFormat.length > 0) lines.push("[extensions]", ...objectFormat);
  lines.push(...other);
  return `${lines.join("\n")}\n`;
}

function configListingEnv(): NodeJS.ProcessEnv {
  const env = sandboxBaseEnv();
  env.GIT_CEILING_DIRECTORIES = tmpdir();
  return env;
}

interface CachedConfig {
  signature: string;
  text: Promise<string>;
}
const shadowConfigCache = new Map<string, CachedConfig>();

/** Shadow config text for `<gitDir>/config`, re-derived when the file changes. */
function readShadowConfig(gitDir: string): Promise<string> {
  const path = join(gitDir, "config");
  const stat = lstatOrNull(path);
  if (!stat || !stat.isFile()) return Promise.resolve(shadowConfigText(""));

  const signature = `${stat.ino}:${stat.size}:${stat.mtimeMs}`;
  const cached = shadowConfigCache.get(path);
  if (cached?.signature === signature) return cached.text;

  // `git config --file --list` parses; it executes nothing and follows no includes.
  const text = new Promise<string>((resolvePromise) => {
    execFile(
      "git",
      ["config", "--file", path, "--list", "-z"],
      { env: configListingEnv(), cwd: tmpdir(), encoding: "utf8", timeout: 5000 },
      (error, stdout) => resolvePromise(shadowConfigText(error ? "" : stdout)),
    );
  });
  shadowConfigCache.set(path, { signature, text });
  if (shadowConfigCache.size > 256) {
    const oldest = shadowConfigCache.keys().next().value;
    if (oldest !== undefined) shadowConfigCache.delete(oldest);
  }
  return text;
}

const SHADOW_ROOT_NAME = `oppi-sandbox-git-${typeof process.getuid === "function" ? process.getuid() : "user"}`;

function ensureShadowRoot(): string {
  const root = join(tmpdir(), SHADOW_ROOT_NAME);
  mkdirSync(root, { recursive: true, mode: 0o700 });
  const stat = lstatSync(root);
  const uid = typeof process.getuid === "function" ? process.getuid() : stat.uid;
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== uid) {
    throw new SandboxGitRefusedError("shadow directory is not owned by the server user");
  }
  return root;
}

function atomicWrite(path: string, content: string): void {
  try {
    if (readFileSync(path, "utf8") === content) return;
  } catch {
    // Missing or unreadable: write below.
  }
  const temp = `${path}.${process.pid}.${Math.random().toString(36).slice(2)}`;
  writeFileSync(temp, content, { mode: 0o600 });
  renameSync(temp, path);
}

function ensureSymlink(path: string, target: string): void {
  try {
    if (readlinkSync(path) === target) return;
    rmSync(path, { force: true, recursive: true });
  } catch {
    // Missing or not a link; create below.
    if (lstatOrNull(path)) rmSync(path, { force: true, recursive: true });
  }
  try {
    symlinkSync(target, path);
  } catch (error) {
    // A concurrent caller created the same link.
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
  }
}

function removeIfPresent(path: string): void {
  if (lstatOrNull(path)) rmSync(path, { force: true, recursive: true });
}

const HEAD_PATTERN = /^(?:ref: refs\/[A-Za-z0-9_./@+-]+|[0-9a-f]{40}|[0-9a-f]{64})\n?$/;

/**
 * Build (or refresh) the host-owned git dir git will read instead of the mount's.
 * Data is symlinked from the mount (index, refs, objects, reflogs); `config`,
 * `info/`, `HEAD`, and hooks belong to the host. `HEAD` is copied because git
 * rejects a symlinked HEAD, and validated because it is the one file git parses
 * for control flow.
 */
async function prepareShadowGitDir(
  repo: SandboxRepo,
): Promise<{ dir: string; objectFormat: "sha1" | "sha256" }> {
  const head = readSmallFile(join(repo.gitDir, "HEAD"), 4096);
  if (head === null || !HEAD_PATTERN.test(head)) {
    throw new SandboxGitRefusedError("HEAD is not a plain ref or object id");
  }

  const key = createHash("sha256").update(repo.gitDir).digest("hex");
  const dir = join(ensureShadowRoot(), key.slice(0, 32));
  mkdirSync(join(dir, "info"), { recursive: true, mode: 0o700 });

  const config = await readShadowConfig(repo.gitDir);
  atomicWrite(join(dir, "config"), config);
  atomicWrite(join(dir, "HEAD"), head.endsWith("\n") ? head : `${head}\n`);

  ensureSymlink(join(dir, "index"), join(repo.gitDir, "index"));
  for (const name of ["refs", "objects", "packed-refs", "logs", "reftable", "shallow"]) {
    const target = join(repo.gitDir, name);
    if (lstatOrNull(target)) ensureSymlink(join(dir, name), target);
    else if (name === "refs" || name === "objects") ensureSymlink(join(dir, name), target);
    else removeIfPresent(join(dir, name));
  }

  const exclude = join(repo.gitDir, "info", "exclude");
  if (lstatOrNull(exclude)) ensureSymlink(join(dir, "info", "exclude"), exclude);
  else removeIfPresent(join(dir, "info", "exclude"));

  return {
    dir,
    objectFormat: /objectformat = sha256/.test(config) ? "sha256" : "sha1",
  };
}
