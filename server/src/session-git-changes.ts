/**
 * Git-derived change review for sessions in their own worktree.
 *
 * A worktree session's changes are what its checkout holds beyond the point it
 * forked from the workspace's main checkout: `git diff <base>` (committed and
 * uncommitted tracked changes) plus untracked files, where `base` is the
 * merge-base of the worktree's HEAD and `main-worktree/HEAD`. Several sessions
 * can share one worktree, so this is the worktree's change set, not one
 * session's; the session's own tool-call touched list (`changeStats.changedFiles`)
 * stays beside it as the per-session hint.
 *
 * Git cost is bounded and read-only (no commits, refs, index writes, or stash):
 * - nothing runs per tool call; a tool end only bumps an in-memory generation;
 * - a turn end runs one snapshot: `rev-parse`, then `merge-base` only when the
 *   (HEAD, target) pair is new, then `diff` and `ls-files` in parallel;
 * - an on-demand read reuses the last snapshot while the worktree's generation,
 *   its index and HEAD mtimes, and a short age bound all still match;
 * - the worktree path is resolved through `git worktree list` once per
 *   (workspace, worktree) per process.
 */

import { existsSync, realpathSync } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, normalize, resolve } from "node:path";

import { execGit, gitTrustForWorkspace, type GitTrust } from "./git-safe.js";
import { countUntrackedFileLines } from "./git-status.js";
import { normalizePath } from "./git-utils.js";
import { resolveHostPath } from "./host.js";
import type { Session, SessionWorktreeChangeStats, Workspace } from "./types.js";
import { MAIN_WORKTREE_ID, resolveWorkspaceWorktree } from "./worktrees.js";

/** Files kept in a full snapshot (listSessionChanges). */
const SNAPSHOT_FILE_CAP = 500;
/** Paths stored in `changeStats.worktree` (persisted and sent with the session). */
const STORED_FILE_CAP = 100;
/** A cached snapshot older than this is recomputed even when nothing else changed. */
const SNAPSHOT_MAX_AGE_MS = 10_000;
const GIT_TIMEOUT_MS = 10_000;
const MAX_BASELINE_BYTES = 10 * 1024 * 1024;

export interface WorktreeChangedFile {
  path: string;
  /** `A`, `M`, `D`, `T` from `git diff --raw`, or `??` for untracked. */
  status: string;
  /** Null for binary files and untracked files too large to count. */
  addedLines: number | null;
  removedLines: number | null;
}

export interface WorktreeChangeSnapshot {
  root: string;
  headSha: string;
  baseSha: string;
  files: WorktreeChangedFile[];
  totalFiles: number;
  addedLines: number;
  removedLines: number;
  computedAt: number;
}

export type WorktreeChangesResult =
  | { kind: "ok"; snapshot: WorktreeChangeSnapshot }
  /** Not a worktree session, the worktree is gone, or git could not read it. */
  | { kind: "unavailable" };

export interface WorktreeChangesContext {
  session: Pick<Session, "workspaceId" | "worktreeId">;
  workspace: Workspace | undefined;
  dataDir: string | undefined;
}

/** A session bound to a checkout other than the workspace's main checkout. */
export function isWorktreeSession(session: Pick<Session, "worktreeId">): boolean {
  return worktreeIdOf(session) !== undefined;
}

function worktreeIdOf(session: Pick<Session, "worktreeId">): string | undefined {
  const id = session.worktreeId?.trim();
  return id && id !== MAIN_WORKTREE_ID ? id : undefined;
}

/** Cache key for a worktree session's checkout, or undefined for any other session. */
function worktreeKey(session: Pick<Session, "workspaceId" | "worktreeId">): string | undefined {
  const worktreeId = worktreeIdOf(session);
  return session.workspaceId && worktreeId ? `${session.workspaceId}\0${worktreeId}` : undefined;
}

interface ResolvedWorktree {
  root: string;
  /** Per-worktree git dir (holds `index` and `HEAD`), when `.git` is a gitfile. */
  gitDir: string | undefined;
}

interface CachedSnapshot {
  snapshot: WorktreeChangeSnapshot;
  generation: number;
  signal: string;
}

const resolvedWorktrees = new Map<string, ResolvedWorktree>();
const mergeBases = new Map<string, string>();
const snapshots = new Map<string, CachedSnapshot>();
const generations = new Map<string, number>();

/**
 * Note that an agent tool ran in a worktree session's checkout. In-memory only:
 * this is the per-tool-call hook and must never run git or touch the disk.
 */
export function noteWorktreeActivity(session: Pick<Session, "workspaceId" | "worktreeId">): void {
  const key = worktreeKey(session);
  if (!key) return;
  generations.set(key, (generations.get(key) ?? 0) + 1);
}

/**
 * The worktree's changes vs its base. `fresh` skips the snapshot cache (turn
 * end); otherwise a cached snapshot is reused while its signals still match.
 */
export async function readWorktreeChanges(
  context: WorktreeChangesContext,
  options: { fresh?: boolean; now?: number } = {},
): Promise<WorktreeChangesResult> {
  const target = await resolveTarget(context);
  if (!target) return { kind: "unavailable" };
  const { key, worktree, trust } = target;
  const now = options.now ?? Date.now();
  const generation = generations.get(key) ?? 0;
  const signal = await cheapSignal(worktree);

  const cached = snapshots.get(key);
  if (
    !options.fresh &&
    cached &&
    cached.snapshot.root === worktree.root &&
    cached.generation === generation &&
    cached.signal === signal &&
    now - cached.snapshot.computedAt < SNAPSHOT_MAX_AGE_MS
  ) {
    return { kind: "ok", snapshot: cached.snapshot };
  }

  const snapshot = await computeSnapshot(worktree.root, trust, now);
  if (!snapshot) {
    snapshots.delete(key);
    return { kind: "unavailable" };
  }
  snapshots.set(key, { snapshot, generation, signal });
  return { kind: "ok", snapshot };
}

export type WorktreeBaselineResult =
  | { kind: "ok"; root: string; baseSha: string; baselineText: string | null }
  | { kind: "unavailable" }
  | { kind: "invalid-path" }
  | { kind: "too-large" };

/**
 * The file's text at the worktree's base, or null when the base has no such
 * file. Reuses the cached snapshot's base when it is still valid, so opening a
 * file after listing costs one `git show`.
 */
export async function readWorktreeBaseline(
  context: WorktreeChangesContext,
  path: string,
): Promise<WorktreeBaselineResult> {
  const relativePath = repoRelativePath(path);
  if (!relativePath) return { kind: "invalid-path" };
  const changes = await readWorktreeChanges(context);
  if (changes.kind !== "ok") return { kind: "unavailable" };
  const { root, baseSha } = changes.snapshot;
  if (!context.workspace) return { kind: "unavailable" };
  const trust = gitTrustForWorkspace(context.workspace);

  const blob = await readBlob(trust, root, baseSha, relativePath);
  if (blob.kind !== "ok") return blob;
  return { kind: "ok", root, baseSha, baselineText: blob.text };
}

/** `<commit>:<path>` as text; `text: null` when the commit has no such file. One spawn. */
async function readBlob(
  trust: GitTrust,
  root: string,
  commit: string,
  relativePath: string,
): Promise<{ kind: "ok"; text: string | null } | { kind: "unavailable" } | { kind: "too-large" }> {
  const shown = await execGit(trust, root, ["cat-file", "blob", `${commit}:${relativePath}`], {
    encoding: "utf8",
    timeout: GIT_TIMEOUT_MS,
    maxBuffer: MAX_BASELINE_BYTES,
  });
  if (!shown.error) return { kind: "ok", text: String(shown.stdout) };
  if (shown.error.code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER") return { kind: "too-large" };
  // A path the commit does not have (added or deleted) or that is not a blob there.
  if (/does not exist in|exists on disk, but not in|bad file/i.test(String(shown.stderr))) {
    return { kind: "ok", text: null };
  }
  return { kind: "unavailable" };
}

export type StoredWorktreeDiffResult =
  | { kind: "ok"; baseSha: string; baselineText: string | null; currentText: string | null }
  | { kind: "unavailable" }
  | { kind: "invalid-path" }
  | { kind: "too-large" };

/**
 * A removed worktree's file at the base and HEAD stored at its last turn end,
 * read from the workspace's main checkout (linked worktrees share its objects).
 * Uncommitted changes went with the worktree, so this is the committed net diff.
 */
export async function readStoredWorktreeDiff(
  context: WorktreeChangesContext & { stored: SessionWorktreeChangeStats | undefined },
  path: string,
): Promise<StoredWorktreeDiffResult> {
  const { workspace, stored } = context;
  if (!workspace || workspace.runtime === "sandbox" || !stored?.baseSha || !stored.headSha) {
    return { kind: "unavailable" };
  }
  const relativePath = repoRelativePath(path);
  if (!relativePath) return { kind: "invalid-path" };
  const root = resolveHostPath(workspace.hostMount);
  if (!existsSync(root)) return { kind: "unavailable" };
  const trust = gitTrustForWorkspace(workspace);
  const [baseline, current] = await Promise.all([
    readBlob(trust, root, stored.baseSha, relativePath),
    readBlob(trust, root, stored.headSha, relativePath),
  ]);
  if (baseline.kind === "too-large" || current.kind === "too-large") return { kind: "too-large" };
  if (baseline.kind !== "ok" || current.kind !== "ok") return { kind: "unavailable" };
  if (baseline.text === null && current.text === null) return { kind: "unavailable" };
  return {
    kind: "ok",
    baseSha: stored.baseSha,
    baselineText: baseline.text,
    currentText: current.text,
  };
}

/** The bounded form stored on `changeStats.worktree` at turn end. */
export function storedWorktreeChangeStats(
  snapshot: WorktreeChangeSnapshot,
): SessionWorktreeChangeStats {
  const changedFiles = snapshot.files.slice(0, STORED_FILE_CAP).map((file) => file.path);
  const overflow = snapshot.totalFiles - changedFiles.length;
  return {
    filesChanged: snapshot.totalFiles,
    changedFiles,
    ...(overflow > 0 ? { changedFilesOverflow: overflow } : {}),
    addedLines: snapshot.addedLines,
    removedLines: snapshot.removedLines,
    baseSha: snapshot.baseSha,
    headSha: snapshot.headSha,
    computedAt: snapshot.computedAt,
  };
}

/**
 * The session's own tool-call touched list as repo-relative paths. `root` is the
 * worktree's real path; an absolute tool path may name it through a symlink
 * (`/var` vs `/private/var`), so it is resolved before relativizing.
 */
export function sessionTouchedPaths(
  session: Pick<Session, "changeStats">,
  root: string | undefined,
): Set<string> {
  return new Set(
    (session.changeStats?.changedFiles ?? [])
      .map((value) => {
        const path = value.trim();
        return normalizePath(root && isAbsolute(path) ? realPathOf(path) : path, root);
      })
      .filter((value) => value.length > 0),
  );
}

function realPathOf(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    try {
      return join(realpathSync(dirname(path)), basename(path));
    } catch {
      return path;
    }
  }
}

// ─── Internals ───

async function resolveTarget(
  context: WorktreeChangesContext,
): Promise<{ key: string; worktree: ResolvedWorktree; trust: GitTrust } | undefined> {
  const { session, workspace, dataDir } = context;
  const key = worktreeKey(session);
  const worktreeId = worktreeIdOf(session);
  if (!workspace || workspace.runtime === "sandbox" || !key || !worktreeId) return undefined;

  const cached = resolvedWorktrees.get(key);
  if (cached && existsSync(cached.root)) {
    return { key, worktree: cached, trust: gitTrustForWorkspace(workspace) };
  }
  resolvedWorktrees.delete(key);

  const listed = await resolveWorkspaceWorktree(workspace, worktreeId, { dataDir }).catch(
    () => undefined,
  );
  if (!listed || listed.isMain || !listed.isGitRepo || !existsSync(listed.path)) return undefined;
  const worktree: ResolvedWorktree = {
    root: listed.path,
    gitDir: await readGitDir(listed.path),
  };
  resolvedWorktrees.set(key, worktree);
  return { key, worktree, trust: gitTrustForWorkspace(workspace) };
}

async function readGitDir(root: string): Promise<string | undefined> {
  try {
    const content = await readFile(join(root, ".git"), "utf8");
    const match = /^gitdir:\s*(.+)\s*$/m.exec(content);
    return match ? resolve(root, match[1].trim()) : undefined;
  } catch {
    // A directory `.git` (not a linked worktree) or an unreadable file.
    return undefined;
  }
}

/** Index and HEAD mtimes: staging, commits, checkouts, and resets move them. */
async function cheapSignal(worktree: ResolvedWorktree): Promise<string> {
  const gitDir = worktree.gitDir;
  if (!gitDir) return "";
  const mtime = async (name: string): Promise<string> => {
    try {
      return String((await stat(join(gitDir, name))).mtimeMs);
    } catch {
      return "-";
    }
  };
  const [index, head] = await Promise.all([mtime("index"), mtime("HEAD")]);
  return `${index}:${head}`;
}

async function git(trust: GitTrust, cwd: string, args: string[]): Promise<string | null> {
  const result = await execGit(trust, cwd, args, {
    encoding: "utf8",
    timeout: GIT_TIMEOUT_MS,
    maxBuffer: 16 * 1024 * 1024,
  });
  return result.error ? null : String(result.stdout);
}

async function computeSnapshot(
  root: string,
  trust: GitTrust,
  now: number,
): Promise<WorktreeChangeSnapshot | undefined> {
  // `main-worktree/HEAD` is the workspace's main checkout HEAD, read from any linked worktree.
  const heads = (await git(trust, root, ["rev-parse", "HEAD", "main-worktree/HEAD"]))
    ?.trim()
    .split("\n");
  const headSha = heads?.[0]?.trim();
  const targetSha = heads?.[1]?.trim();
  if (!headSha || !targetSha) return undefined;

  const baseKey = `${headSha}\0${targetSha}`;
  let baseSha = mergeBases.get(baseKey);
  if (!baseSha) {
    baseSha = (await git(trust, root, ["merge-base", headSha, targetSha]))?.trim();
    if (!baseSha) return undefined;
    mergeBases.set(baseKey, baseSha);
  }

  const [diffOut, untrackedOut] = await Promise.all([
    git(trust, root, [
      "diff",
      "--raw",
      "--numstat",
      "-z",
      "--no-renames",
      "--no-ext-diff",
      "--no-textconv",
      baseSha,
      "--",
    ]),
    git(trust, root, ["ls-files", "--others", "--exclude-standard", "-z"]),
  ]);
  if (diffOut === null || untrackedOut === null) return undefined;

  const files = parseRawNumstat(diffOut);
  const tracked = new Set(files.map((file) => file.path));
  const untracked = untrackedOut
    .split("\0")
    .filter((path) => path.length > 0 && !tracked.has(path));
  const untrackedLines = await countUntrackedFileLines(root, untracked, trust);
  for (const path of untracked) {
    const lines = untrackedLines.get(path);
    files.push({
      path,
      status: "??",
      addedLines: lines ?? null,
      removedLines: lines === undefined ? null : 0,
    });
  }
  files.sort((lhs, rhs) => lhs.path.localeCompare(rhs.path));

  let addedLines = 0;
  let removedLines = 0;
  for (const file of files) {
    addedLines += file.addedLines ?? 0;
    removedLines += file.removedLines ?? 0;
  }

  return {
    root,
    headSha,
    baseSha,
    files: files.slice(0, SNAPSHOT_FILE_CAP),
    totalFiles: files.length,
    addedLines,
    removedLines,
    computedAt: now,
  };
}

/**
 * `git diff --raw --numstat -z --no-renames`: raw records first
 * (`:<modes> <shas> <status>\0<path>\0`), then numstat records
 * (`<added>\t<removed>\t<path>\0`, `-\t-` for binary).
 */
function parseRawNumstat(output: string): WorktreeChangedFile[] {
  const tokens = output.split("\0");
  const byPath = new Map<string, WorktreeChangedFile>();
  for (let index = 0; index < tokens.length; index++) {
    const token = tokens[index];
    if (!token) continue;
    if (token.startsWith(":")) {
      const status = token.trim().split(/\s+/).pop()?.charAt(0) ?? "M";
      const path = tokens[++index];
      if (path) byPath.set(path, { path, status, addedLines: null, removedLines: null });
      continue;
    }
    const match = /^(-|\d+)\t(-|\d+)\t(.*)$/s.exec(token);
    if (!match) continue;
    const file = byPath.get(match[3]);
    if (!file) continue;
    file.addedLines = match[1] === "-" ? null : Number.parseInt(match[1], 10);
    file.removedLines = match[2] === "-" ? null : Number.parseInt(match[2], 10);
  }
  return [...byPath.values()];
}

/** A repo-relative path with no `..` escape, or null. */
function repoRelativePath(path: string): string | null {
  const trimmed = path.trim().replace(/\\/g, "/");
  if (!trimmed || isAbsolute(trimmed)) return null;
  const normalized = normalize(trimmed).replace(/\\/g, "/");
  if (normalized === "." || normalized.startsWith("../") || normalized === "..") return null;
  return normalized.replace(/^\.\//, "");
}
