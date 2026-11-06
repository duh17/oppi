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
 * Git cost is bounded and read-only (no commits, refs, index writes, or stash).
 * Only plumbing runs against the worktree: porcelain `git diff` and `git status`
 * refresh and rewrite the index, which an agent's own `git commit` would collide
 * with on `index.lock`.
 * - nothing runs per tool call; a tool end only bumps an in-memory generation;
 * - a turn in which a tool ran ends in one snapshot: `rev-parse`, then
 *   `merge-base` only when the (HEAD, target) pair is new, then `diff-index`
 *   and `ls-files` in parallel;
 * - one read runs per worktree at a time; callers that arrive while it runs
 *   (several sessions in one worktree, a list request) share it;
 * - an on-demand read reuses the last snapshot while the worktree's generation,
 *   its index, HEAD, and HEAD reflog mtimes, the main checkout's HEAD and branch
 *   reflog mtimes, and a short age bound all still match (a ref moved without a reflog
 *   entry waits out the age bound);
 * - the worktree path is resolved through `git worktree list` once per
 *   (workspace, worktree) per process; a worktree that is gone is not looked up
 *   again for 30 seconds.
 */

import { existsSync, realpathSync } from "node:fs";
import { open, readFile, stat } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, normalize, resolve } from "node:path";

import { execGit, gitTrustForWorkspace, type GitTrust } from "./git-safe.js";
import { gitLineCount } from "./git-status.js";
import { normalizePath } from "./path-utils.js";
import { resolveHostPath } from "./host.js";
import type { Session, SessionWorktreeChangeStats, Workspace } from "./types.js";
import {
  isWorktreeRemovalPending,
  MAIN_WORKTREE_ID,
  resolveWorkspaceWorktree,
} from "./worktrees.js";

/** Files kept in a full snapshot (listSessionChanges). */
const SNAPSHOT_FILE_CAP = 500;
/** Paths stored in `changeStats.worktree` (persisted and sent with the session). */
const STORED_FILE_CAP = 100;
/** A cached snapshot older than this is recomputed even when nothing else changed. */
const SNAPSHOT_MAX_AGE_MS = 10_000;
const GIT_TIMEOUT_MS = 10_000;
const MAX_BASELINE_BYTES = 10 * 1024 * 1024;
/** Untracked files whose lines are counted; the rest list with null counts. */
const UNTRACKED_LINE_COUNT_FILES = 200;
const UNTRACKED_LINE_COUNT_MAX_BYTES = 256 * 1024;
/** `ls-files --others` output kept; past it the untracked list is cut short, not dropped. */
const UNTRACKED_LIST_MAX_BYTES = 4 * 1024 * 1024;
/** How long a worktree that could not be resolved is treated as gone without asking git. */
const MISSING_WORKTREE_TTL_MS = 30_000;
const MERGE_BASE_CACHE_MAX = 256;

export interface WorktreeChangedFile {
  path: string;
  /** `A`, `M`, `D`, `T` from `git diff-index --raw`, or `??` for untracked. */
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
  /**
   * HEAD is the merge-base with the main checkout and holds commits made in the
   * worktree (its reflog, or the own commits stored at the last turn end): the
   * worktree landed. A worktree that only synced with main (fast-forward,
   * rebase, or reset onto it with no commits of its own) or was reset back to
   * its base is not landed. See `resolveBase`.
   */
  landed: boolean;
  /**
   * What the landing decision read from the stored commits (only when HEAD was
   * the merge-base): their `storedKey` when they held the worktree's own
   * commits, `no-own-commits` when not, or null when the result does not depend
   * on them. Cache hits and shared reads must fit it.
   */
  storedDependency: string | null;
}

/** What the last turn end stored: its base and HEAD. */
export interface StoredWorktreeCommits {
  baseSha: string;
  headSha: string;
}

export type WorktreeChangesResult =
  | { kind: "ok"; snapshot: WorktreeChangeSnapshot }
  /** Not a worktree session, the worktree is gone, or git could not read it. */
  | { kind: "unavailable" };

export interface WorktreeChangesContext {
  session: Pick<Session, "workspaceId" | "worktreeId">;
  workspace: Workspace | undefined;
  dataDir: string | undefined;
  /**
   * The base and HEAD stored at the last turn end. A landed worktree whose HEAD
   * is still the stored HEAD keeps being measured from the stored base instead
   * of reporting zero changes. A cached or shared read is reused for other
   * stored commits only when it did not depend on them.
   */
  stored?: StoredWorktreeCommits;
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
  workspaceId: string;
  worktreeId: string;
  /** Per-worktree git dir (holds `index` and `HEAD`), when `.git` is a gitfile. */
  gitDir: string | undefined;
  /** The repository's common dir (the main checkout's `.git`). */
  commonDir: string | undefined;
}

interface CachedSnapshot {
  snapshot: WorktreeChangeSnapshot;
  generation: number;
  signal: string;
}

const resolvedWorktrees = new Map<string, ResolvedWorktree>();
/** Worktree key → time until which it is treated as gone. */
const missingWorktrees = new Map<string, number>();
/** `<head>\0<target>` → merge-base, and `contains\0<commit>\0<head>` → `"1"`/`"0"`. */
const mergeBases = new Map<string, string>();
const snapshots = new Map<string, CachedSnapshot>();
const generations = new Map<string, number>();
const inFlight = new Map<string, { generation: number; promise: Promise<WorktreeChangesResult> }>();

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
 * A read already running for this worktree with no tool activity since it
 * started is shared, whoever asked; the join is registered synchronously.
 */
export function readWorktreeChanges(
  context: WorktreeChangesContext,
  options: { fresh?: boolean } = {},
): Promise<WorktreeChangesResult> {
  const key = worktreeKey(context.session);
  if (!key) return Promise.resolve({ kind: "unavailable" });
  const generation = generations.get(key) ?? 0;
  const running = inFlight.get(key);
  let shared: Promise<WorktreeChangesResult>;
  if (running && running.generation === generation) {
    shared = running.promise;
  } else {
    const promise = readUncoalesced(key, context, options, generation).finally(() => {
      if (inFlight.get(key)?.promise === promise) inFlight.delete(key);
    });
    inFlight.set(key, { generation, promise });
    shared = promise;
  }
  // A shared read that consulted other stored commits (a landing decision) is
  // read again for this caller's.
  return shared.then((result) =>
    result.kind === "ok" && !fitsStored(result.snapshot, context.stored)
      ? readUncoalesced(key, context, { fresh: true }, generation)
      : result,
  );
}

function storedKey(stored: StoredWorktreeCommits | undefined): string {
  return stored ? `${stored.baseSha}\0${stored.headSha}` : "";
}

/** The snapshot answers for these stored commits: it did not depend on them, or used the same. */
function fitsStored(
  snapshot: WorktreeChangeSnapshot,
  stored: StoredWorktreeCommits | undefined,
): boolean {
  const dependency = snapshot.storedDependency;
  if (dependency === null) return true;
  if (dependency === NO_OWN_COMMITS) return !hasOwnCommits(stored);
  return dependency === storedKey(stored);
}

/** Dependency of a read whose stored commits held none of the worktree's own. */
const NO_OWN_COMMITS = "no-own-commits";

function hasOwnCommits(stored: StoredWorktreeCommits | undefined): stored is StoredWorktreeCommits {
  return stored !== undefined && stored.headSha !== stored.baseSha;
}

async function readUncoalesced(
  key: string,
  context: WorktreeChangesContext,
  options: { fresh?: boolean },
  generation: number,
): Promise<WorktreeChangesResult> {
  const target = await resolveTarget(key, context);
  if (!target) return { kind: "unavailable" };
  const { worktree, trust } = target;
  const now = Date.now();
  const signal = await cheapSignal(worktree);

  const cached = snapshots.get(key);
  if (
    !options.fresh &&
    cached &&
    cached.snapshot.root === worktree.root &&
    cached.generation === generation &&
    cached.signal === signal &&
    fitsStored(cached.snapshot, context.stored) &&
    now - cached.snapshot.computedAt < SNAPSHOT_MAX_AGE_MS
  ) {
    return { kind: "ok", snapshot: cached.snapshot };
  }

  const snapshot = await computeSnapshot(worktree.root, worktree, trust, now, context.stored);
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
 * file after listing costs one `git cat-file`.
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
  key: string,
  context: WorktreeChangesContext,
): Promise<{ worktree: ResolvedWorktree; trust: GitTrust } | undefined> {
  const { session, workspace, dataDir } = context;
  const worktreeId = worktreeIdOf(session);
  if (!workspace || workspace.runtime === "sandbox" || !worktreeId) return undefined;
  const trust = gitTrustForWorkspace(workspace);

  const cached = resolvedWorktrees.get(key);
  if (
    cached &&
    existsSync(cached.root) &&
    !isWorktreeRemovalPending(cached.workspaceId, cached.worktreeId, cached.root)
  ) {
    return { worktree: cached, trust };
  }
  if (cached) {
    resolvedWorktrees.delete(key);
    snapshots.delete(key);
  }
  if ((missingWorktrees.get(key) ?? 0) > Date.now()) return undefined;

  const listed = await resolveWorkspaceWorktree(workspace, worktreeId, { dataDir }).catch(
    () => undefined,
  );
  if (!listed || listed.isMain || !listed.isGitRepo || !existsSync(listed.path)) {
    missingWorktrees.set(key, Date.now() + MISSING_WORKTREE_TTL_MS);
    // Gone: its activity count goes too (a read in flight keeps the generation it took).
    generations.delete(key);
    return undefined;
  }
  missingWorktrees.delete(key);
  const gitDir = await readGitDir(listed.path);
  const worktree: ResolvedWorktree = {
    root: listed.path,
    workspaceId: workspace.id,
    worktreeId,
    gitDir,
    commonDir: gitDir ? await readCommonDir(gitDir) : undefined,
  };
  resolvedWorktrees.set(key, worktree);
  return { worktree, trust };
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

async function readCommonDir(gitDir: string): Promise<string | undefined> {
  try {
    return resolve(gitDir, (await readFile(join(gitDir, "commondir"), "utf8")).trim());
  } catch {
    return undefined;
  }
}

/**
 * Mtimes that move when the snapshot's inputs move: the worktree's index
 * (staging, most commits), HEAD (checkouts), and HEAD reflog (every commit,
 * reset, or checkout here), and the main checkout's HEAD and checked-out branch
 * reflogs (its HEAD is the target the base is measured from, and a landing is
 * read from them). With reflogs off, a commit made outside the agent waits for
 * the age bound.
 */
async function cheapSignal(worktree: ResolvedWorktree): Promise<string> {
  const { gitDir, commonDir } = worktree;
  if (!gitDir) return "";
  const mtime = async (path: string | undefined): Promise<string> => {
    if (!path) return "-";
    try {
      return String((await stat(path)).mtimeMs);
    } catch {
      return "-";
    }
  };
  const mainReflogs = commonDir ? await mainCheckoutReflogs(commonDir) : [];
  const parts = await Promise.all([
    mtime(join(gitDir, "index")),
    mtime(join(gitDir, "HEAD")),
    mtime(join(gitDir, "logs", "HEAD")),
    ...mainReflogs.map((path) => mtime(path)),
  ]);
  return parts.join(":");
}

function rememberMergeBase(key: string, value: string): void {
  if (mergeBases.size >= MERGE_BASE_CACHE_MAX) {
    const oldest = mergeBases.keys().next().value;
    if (oldest !== undefined) mergeBases.delete(oldest);
  }
  mergeBases.set(key, value);
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
  gitDirs: { gitDir: string | undefined; commonDir: string | undefined },
  trust: GitTrust,
  now: number,
  stored: StoredWorktreeCommits | undefined,
): Promise<WorktreeChangeSnapshot | undefined> {
  // `main-worktree/HEAD` is the workspace's main checkout HEAD, read from any linked worktree.
  const heads = (await git(trust, root, ["rev-parse", "HEAD", "main-worktree/HEAD"]))
    ?.trim()
    .split("\n");
  const headSha = heads?.[0]?.trim();
  const targetSha = heads?.[1]?.trim();
  if (!headSha || !targetSha) return undefined;

  const base = await resolveBase(trust, root, gitDirs, headSha, targetSha, stored);
  if (!base) return undefined;
  const { baseSha, landed } = base;
  // Only a HEAD that is the merge-base reads the stored commits, and then only
  // whether they held commits of the worktree's own, and if so which.
  const storedDependency = !base.consultedStored
    ? null
    : hasOwnCommits(stored)
      ? storedKey(stored)
      : NO_OWN_COMMITS;

  const [diffOut, untracked] = await Promise.all([
    // Plumbing: compares the index's stat data without refreshing or writing it.
    git(trust, root, ["diff-index", "--raw", "--numstat", "-z", "--no-renames", baseSha, "--"]),
    listUntracked(trust, root),
  ]);
  if (diffOut === null || untracked === undefined) return undefined;

  const files = parseRawNumstat(diffOut);
  const tracked = new Set(files.map((file) => file.path));
  const untrackedPaths = untracked.filter((path) => !tracked.has(path));
  const untrackedLines = await countUntrackedLines(
    root,
    untrackedPaths.slice(0, UNTRACKED_LINE_COUNT_FILES),
  );
  for (const path of untrackedPaths) {
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
    landed,
    storedDependency,
  };
}

/**
 * The merge-base of HEAD and the main checkout's HEAD, and whether the worktree
 * landed. HEAD being the merge-base alone is not a landing: a worktree with no
 * commits of its own that synced with main (fast-forward, rebase, reset) or was
 * reset to its base looks the same. Evidence, in order:
 *
 * 1. The landing's own record. A fast-forward landing (integrate-worktree,
 *    `merge --ff-only`, `update-ref`) leaves an entry in the main checkout's
 *    reflog that moved it to this worktree's HEAD; its old sha is main's tip
 *    just before the landing, the right base whether the worktree committed
 *    plainly, rebased (fixups and autosquash too), or merged main. The reflog
 *    of the branch main has checked out is read first: it has no `checkout`
 *    entries, and `git update-ref` on that branch from another worktree (the
 *    land queue) logs only there. `<commonDir>/logs/HEAD` is the fallback, its
 *    `checkout:` entries skipped (checking a branch out again records old sha
 *    = whatever was checked out before). The newest entry with new sha HEAD and
 *    a different old sha counts when HEAD was made in this
 *    worktree and one cached `merge-base --is-ancestor` shows the old sha is in
 *    HEAD. "Made here" is read from the worktree's own HEAD reflog: an entry
 *    reaching HEAD that created a commit (`commit…`, a rebase or
 *    `pull --rebase` pick, fixup, squash, reword, edit, or continue,
 *    `cherry-pick`, `revert`, or a `merge`/`pull` that made a merge commit).
 *    Without it, HEAD came from outside (a
 *    fast-forward sync, `reset`, `checkout`, or a rebase that only fast-forwarded
 *    onto main), and main reaching that sha is main's own commit or another
 *    worktree's landing, never evidence for this one.
 * 2. The commits stored at the last turn end were the worktree's own (stored
 *    HEAD is not stored base) and HEAD is still that stored HEAD: measure from
 *    the stored base (an ancestor of the stored HEAD by construction). This is
 *    also what a `--no-ff` landing uses: main's new tip is a merge commit, not
 *    HEAD, so its reflog has no entry for HEAD.
 * 3. Those stored own commits are still in HEAD but HEAD moved (a sync after
 *    landing): landed, measured from the merge-base, and the turn end and the
 *    list keep the stored value instead of a false zero.
 *
 * Only 2 and 3 apply, so a commit and a landing in the same turn reads as zero,
 * with reflogs off (`core.logAllRefUpdates=false`), when the landing entry is
 * past the last 64 KB of the reflog, or for a `--no-ff` landing.
 */
async function resolveBase(
  trust: GitTrust,
  root: string,
  gitDirs: { gitDir: string | undefined; commonDir: string | undefined },
  headSha: string,
  targetSha: string,
  stored: StoredWorktreeCommits | undefined,
): Promise<{ baseSha: string; landed: boolean; consultedStored: boolean } | undefined> {
  const baseKey = `${headSha}\0${targetSha}`;
  let mergeBase = mergeBases.get(baseKey);
  if (!mergeBase) {
    mergeBase = (await git(trust, root, ["merge-base", headSha, targetSha]))?.trim();
    if (!mergeBase) return undefined;
    rememberMergeBase(baseKey, mergeBase);
  }
  if (mergeBase !== headSha) return { baseSha: mergeBase, landed: false, consultedStored: false };

  const { gitDir, commonDir } = gitDirs;
  const landingBase =
    gitDir && commonDir && (await madeInWorktree(gitDir, headSha))
      ? await mainTipBeforeLanding(commonDir, headSha)
      : undefined;
  if (landingBase && (await contains(trust, root, landingBase, headSha))) {
    return { baseSha: landingBase, landed: true, consultedStored: false };
  }

  if (!hasOwnCommits(stored)) return { baseSha: mergeBase, landed: false, consultedStored: true };
  if (stored.headSha === headSha) {
    return { baseSha: stored.baseSha, landed: true, consultedStored: true };
  }
  const landed = await contains(trust, root, stored.headSha, headSha);
  return { baseSha: mergeBase, landed, consultedStored: true };
}

/** `commit` is an ancestor of (or is) `head`. One cached `merge-base --is-ancestor`. */
async function contains(
  trust: GitTrust,
  root: string,
  commit: string,
  head: string,
): Promise<boolean> {
  if (commit === head) return true;
  const containsKey = `contains\0${commit}\0${head}`;
  let cached = mergeBases.get(containsKey);
  if (cached === undefined) {
    const ancestor = await execGit(trust, root, ["merge-base", "--is-ancestor", commit, head], {
      timeout: GIT_TIMEOUT_MS,
    });
    cached = ancestor.error ? "0" : "1";
    rememberMergeBase(containsKey, cached);
  }
  return cached === "1";
}

const REFLOG_TAIL_BYTES = 64 * 1024;
const REFLOG_LINE = /^([0-9a-f]{40,64}) ([0-9a-f]{40,64}) [^\t]*\t(.*)$/;
const ZERO_SHA = /^0+$/;

/**
 * Main's tip just before it moved to `headSha`: the old sha of the newest entry
 * in the main checkout's reflogs (its checked-out branch, then HEAD without
 * `checkout:` entries) whose new sha is `headSha` and whose old sha differs.
 * File reads of the last 64 KB of each: no git process.
 */
async function mainTipBeforeLanding(
  commonDir: string,
  headSha: string,
): Promise<string | undefined> {
  for (const path of await mainCheckoutReflogs(commonDir)) {
    const lines = await readReflogTail(path);
    for (let index = lines.length - 1; index >= 0; index--) {
      const entry = REFLOG_LINE.exec(lines[index]);
      if (!entry || entry[2] !== headSha || entry[3].startsWith("checkout:")) continue;
      if (entry[1] !== headSha && !ZERO_SHA.test(entry[1])) return entry[1];
    }
  }
  return undefined;
}

/**
 * Reflog messages of entries that created a commit: `commit…`, `cherry-pick`,
 * `revert`, a step of `rebase` or `pull --rebase` that made one
 * (`rebase -i (pick)`, `pull --rebase . main (fixup)`), and a `merge` or
 * `pull` that made a merge commit (`pull . main: Merge made by …`).
 */
const CREATED_HERE =
  /^(?:commit(?: \([a-z]+\))?:|cherry-pick|revert|(?:rebase|pull)\b[^(:]*\((?:pick|fixup|squash|reword|edit|continue)\)|(?:merge|pull)\b[^:]*: Merge made by)/;

/** The worktree's HEAD reflog shows an entry that created `headSha` here. */
async function madeInWorktree(gitDir: string, headSha: string): Promise<boolean> {
  const lines = await readReflogTail(join(gitDir, "logs", "HEAD"));
  return lines.some((line) => {
    const entry = REFLOG_LINE.exec(line);
    return entry !== null && entry[2] === headSha && CREATED_HERE.test(entry[3]);
  });
}

/** The reflog of the branch the main checkout has checked out (when it names one), then its HEAD reflog. */
async function mainCheckoutReflogs(commonDir: string): Promise<string[]> {
  const head = join(commonDir, "logs", "HEAD");
  try {
    const ref = /^ref:\s*(refs\/heads\/\S+)$/.exec(
      (await readFile(join(commonDir, "HEAD"), "utf8")).trim(),
    )?.[1];
    if (ref && !ref.split("/").includes("..")) return [join(commonDir, "logs", ref), head];
  } catch {
    // Unreadable: HEAD's reflog only.
  }
  return [head];
}

async function readReflogTail(path: string): Promise<string[]> {
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    handle = await open(path, "r");
    const { size } = await handle.stat();
    const length = Math.min(size, REFLOG_TAIL_BYTES);
    const buffer = Buffer.alloc(length);
    await handle.read(buffer, 0, length, size - length);
    const lines = buffer
      .toString("utf8")
      .split("\n")
      .filter((line) => line.length > 0);
    // A cut first line is dropped.
    return size > length ? lines.slice(1) : lines;
  } catch {
    return [];
  } finally {
    await handle?.close().catch(() => {});
  }
}

/**
 * The live read cannot show a landed worktree that has since synced with main
 * (its HEAD is main's, so it reads as zero); the value stored at the last turn
 * end is the answer for both the turn end and the list.
 */
export function keepsStoredChanges(
  snapshot: WorktreeChangeSnapshot,
  stored: Pick<SessionWorktreeChangeStats, "filesChanged"> | undefined,
): boolean {
  return snapshot.landed && snapshot.totalFiles === 0 && (stored?.filesChanged ?? 0) > 0;
}

/**
 * Untracked paths. A listing past `UNTRACKED_LIST_MAX_BYTES` keeps the complete
 * entries it read (the list and its count are then a lower bound) rather than
 * making the whole snapshot unavailable.
 */
async function listUntracked(trust: GitTrust, root: string): Promise<string[] | undefined> {
  const result = await execGit(trust, root, ["ls-files", "--others", "--exclude-standard", "-z"], {
    encoding: "utf8",
    timeout: GIT_TIMEOUT_MS,
    maxBuffer: UNTRACKED_LIST_MAX_BYTES,
  });
  const entries = String(result.stdout).split("\0");
  if (!result.error) return entries.filter((path) => path.length > 0);
  if (result.error.code !== "ERR_CHILD_PROCESS_STDIO_MAXBUFFER") return undefined;
  // The last entry may be cut mid-path.
  return entries.slice(0, -1).filter((path) => path.length > 0);
}

/** Line counts for small text files, read off the event loop's critical path. */
async function countUntrackedLines(root: string, paths: string[]): Promise<Map<string, number>> {
  const counts = new Map<string, number>();
  for (const path of paths) {
    try {
      const fullPath = join(root, path);
      const info = await stat(fullPath);
      if (!info.isFile() || info.size === 0 || info.size > UNTRACKED_LINE_COUNT_MAX_BYTES) continue;
      const content = await readFile(fullPath, "utf8");
      // Likely binary: NUL in the first 8 KB, as git decides.
      if (content.slice(0, 8192).includes("\0")) continue;
      counts.set(path, gitLineCount(content));
    } catch {
      // Vanished or unreadable: listed without a count.
    }
  }
  return counts;
}

/**
 * `git diff-index --raw --numstat -z --no-renames`: raw records first
 * (`:<modes> <shas> <status>\0<path>\0`), then numstat records
 * (`<added>\t<removed>\t<path>\0`, `-\t-` for binary). A raw record with no
 * numstat record is a file whose stat data changed but whose content did not
 * (diff-index never refreshes the index), so it is not a change.
 */
function parseRawNumstat(output: string): WorktreeChangedFile[] {
  const tokens = output.split("\0");
  const statuses = new Map<string, string>();
  const files: WorktreeChangedFile[] = [];
  for (let index = 0; index < tokens.length; index++) {
    const token = tokens[index];
    if (!token) continue;
    if (token.startsWith(":")) {
      const status = token.trim().split(/\s+/).pop()?.charAt(0) ?? "M";
      const path = tokens[++index];
      if (path) statuses.set(path, status);
      continue;
    }
    const match = /^(-|\d+)\t(-|\d+)\t(.*)$/s.exec(token);
    if (!match) continue;
    const status = statuses.get(match[3]);
    if (!status) continue;
    files.push({
      path: match[3],
      status,
      addedLines: match[1] === "-" ? null : Number.parseInt(match[1], 10),
      removedLines: match[2] === "-" ? null : Number.parseInt(match[2], 10),
    });
  }
  return files;
}

/** A repo-relative path with no `..` escape, or null. */
function repoRelativePath(path: string): string | null {
  const trimmed = path.trim().replace(/\\/g, "/");
  // A NUL would make the spawn throw instead of failing the read.
  if (!trimmed || isAbsolute(trimmed) || trimmed.includes("\0")) return null;
  const normalized = normalize(trimmed).replace(/\\/g, "/");
  if (normalized === "." || normalized.startsWith("../") || normalized === "..") return null;
  return normalized.replace(/^\.\//, "");
}
