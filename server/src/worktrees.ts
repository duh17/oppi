import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, realpathSync } from "node:fs";
import { basename, join, relative, resolve, sep } from "node:path";

import { resolveHostPath } from "./host.js";
import { DEFAULT_DATA_DIR } from "./storage/config-store.js";
import type {
  CreateWorkspaceWorktreeRequest,
  OpenWorkspaceWorktreeRequest,
  PreviewWorkspaceWorktreeRequest,
  Workspace,
  WorkspaceWorktree,
  WorkspaceWorktreeIntegrationMode,
  WorkspaceWorktreePreview,
  WorkspaceWorktreePreviewFile,
} from "./types.js";

const MAIN_WORKTREE_ID = "main";
const PROJECT_WORKTREES_DIR = ".pi/worktrees";
const DATA_DIR_WORKTREES_DIR = "worktrees";

type WorktreePorcelainRecord = {
  path: string;
  headSha: string | null;
  branch: string | null;
};

type ListWorkspaceWorktreesOptions = {
  dataDir?: string;
  sessionCountsByWorktreeId?: ReadonlyMap<string, number>;
};

type GitResult = {
  status: number;
  stdout: string;
  stderr: string;
};

const INTEGRATION_MODES = new Set<WorkspaceWorktreeIntegrationMode>(["merge", "squash", "ff-only"]);

export interface WorkspaceWorktreeLifecycleOptions {
  dataDir: string;
}

export interface RemoveWorkspaceWorktreeOptions extends WorkspaceWorktreeLifecycleOptions {
  worktreeId: string;
  force?: boolean;
  sessionCount?: number;
  activeSessionCount?: number;
}

export class WorkspaceWorktreeError extends Error {
  constructor(
    public readonly statusCode: number,
    message: string,
  ) {
    super(message);
    this.name = "WorkspaceWorktreeError";
  }
}

function safeRealpath(path: string): string {
  try {
    return realpathSync(resolve(path));
  } catch {
    return resolve(path);
  }
}

function runGit(cwd: string, args: string[]): string | null {
  const result = runGitResult(cwd, args, 5000);
  return result.status === 0 ? result.stdout : null;
}

function runGitResult(cwd: string, args: string[], timeout = 15_000): GitResult {
  try {
    return {
      status: 0,
      stdout: execFileSync("git", args, {
        cwd,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        timeout,
      }),
      stderr: "",
    };
  } catch (error: unknown) {
    const childError = error as { status?: unknown; stdout?: unknown; stderr?: unknown };
    return {
      status: typeof childError.status === "number" ? childError.status : 1,
      stdout: typeof childError.stdout === "string" ? childError.stdout : "",
      stderr: typeof childError.stderr === "string" ? childError.stderr : "",
    };
  }
}

function runGitOrThrow(cwd: string, args: string[], statusCode = 409): string {
  try {
    return execFileSync("git", args, {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 60_000,
    });
  } catch (error: unknown) {
    const stderr =
      typeof (error as { stderr?: unknown }).stderr === "string"
        ? (error as { stderr: string }).stderr.trim()
        : "";
    const stdout =
      typeof (error as { stdout?: unknown }).stdout === "string"
        ? (error as { stdout: string }).stdout.trim()
        : "";
    const detail = stderr || stdout || `git ${args.join(" ")} failed`;
    throw new WorkspaceWorktreeError(statusCode, detail);
  }
}

function branchName(raw: string | null): string | null {
  if (!raw) return null;
  if (raw.startsWith("refs/heads/")) return raw.slice("refs/heads/".length);
  return raw;
}

function parseWorktreePorcelain(raw: string): WorktreePorcelainRecord[] {
  const records: WorktreePorcelainRecord[] = [];
  let current: Partial<WorktreePorcelainRecord> | undefined;

  const flush = (): void => {
    if (current?.path) {
      records.push({
        path: current.path,
        headSha: current.headSha ?? null,
        branch: current.branch ?? null,
      });
    }
    current = undefined;
  };

  for (const line of raw.split("\n")) {
    if (line.trim() === "") {
      flush();
      continue;
    }

    const space = line.indexOf(" ");
    const key = space === -1 ? line : line.slice(0, space);
    const value = space === -1 ? "" : line.slice(space + 1);

    switch (key) {
      case "worktree":
        flush();
        current = { path: value, headSha: null, branch: null };
        break;
      case "HEAD":
        if (current) current.headSha = value || null;
        break;
      case "branch":
        if (current) current.branch = branchName(value);
        break;
      case "detached":
        if (current) current.branch = null;
        break;
    }
  }

  flush();
  return records;
}

function worktreeIdForPath(path: string): string {
  const bytes = Buffer.from(safeRealpath(path), "utf8");
  return `wt_${bytes.toString("base64url")}`;
}

function shortHash(value: string): string {
  return createHash("sha256").update(value).digest("base64url").slice(0, 8);
}

function pathSegment(value: string, fallback: string, maxLength = 48): string {
  const slug = value
    .trim()
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, maxLength);
  return slug || fallback;
}

function workspacePathSegment(workspaceId: string): string {
  if (/^[A-Za-z0-9._-]+$/.test(workspaceId)) return workspaceId;
  return `${pathSegment(workspaceId, "workspace", 40)}-${shortHash(workspaceId)}`;
}

function worktreeIdForBranch(branch: string): string {
  return `wt_${pathSegment(branch, "worktree", 48)}-${shortHash(branch)}`;
}

function defaultDataDir(): string {
  return process.env.OPPI_DATA_DIR?.trim() || DEFAULT_DATA_DIR;
}

export function managedWorktreesRoot(dataDir: string, workspaceId: string): string {
  return resolve(dataDir, DATA_DIR_WORKTREES_DIR, workspacePathSegment(workspaceId));
}

export function hasManagedWorkspaceWorktreeDirectory(
  dataDir: string,
  workspaceId: string,
): boolean {
  const root = managedWorktreesRoot(dataDir, workspaceId);
  try {
    return readdirSync(root, { withFileTypes: true }).some(
      (entry) => entry.isDirectory() && /^[A-Za-z0-9._-]+$/.test(entry.name),
    );
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") {
      return false;
    }
    return true;
  }
}

function projectManagedWorktreesRoot(workspaceRoot: string): string {
  return resolve(workspaceRoot, PROJECT_WORKTREES_DIR);
}

function isPathWithin(parent: string, child: string): boolean {
  const resolvedParent = safeRealpath(parent);
  const resolvedChild = safeRealpath(child);
  return resolvedChild === resolvedParent || resolvedChild.startsWith(`${resolvedParent}${sep}`);
}

function directChildName(parent: string, child: string): string | undefined {
  const rel = relative(safeRealpath(parent), safeRealpath(child));
  if (!rel || rel === "." || rel.startsWith("..") || rel.split(sep).length !== 1) {
    return undefined;
  }
  return rel;
}

function dataDirManagedWorktreeId(
  dataDir: string | undefined,
  workspaceId: string,
  path: string,
): string | undefined {
  const root = managedWorktreesRoot(dataDir ?? defaultDataDir(), workspaceId);
  const child = directChildName(root, path);
  return child && /^[A-Za-z0-9._-]+$/.test(child) ? child : undefined;
}

function displayNameForWorktree(record: WorktreePorcelainRecord, isMain: boolean): string {
  if (isMain) return "Main checkout";
  if (record.branch) return record.branch;
  return basename(record.path) || "Detached checkout";
}

function fallbackMainWorktree(path: string, isGitRepo: boolean): WorkspaceWorktree {
  const resolvedPath = safeRealpath(path);
  const branch = isGitRepo
    ? branchName(runGit(resolvedPath, ["branch", "--show-current"])?.trim() ?? null)
    : null;
  const headSha = isGitRepo
    ? runGit(resolvedPath, ["rev-parse", "--short", "HEAD"])?.trim() || null
    : null;
  return {
    id: MAIN_WORKTREE_ID,
    name: "Main checkout",
    path: resolvedPath,
    branch,
    headSha,
    isMain: true,
    isGitRepo,
    managedByOppi: false,
  };
}

function requireWorkspaceGitRoot(workspace: Workspace): string {
  const hostMount = workspace.hostMount?.trim();
  if (!hostMount) {
    throw new WorkspaceWorktreeError(400, "Workspace has no host mount");
  }

  const hostPath = resolveHostPath(hostMount);
  if (!existsSync(hostPath)) {
    throw new WorkspaceWorktreeError(400, "Workspace host mount does not exist");
  }

  const rootOut = runGit(safeRealpath(hostPath), ["rev-parse", "--show-toplevel"]);
  if (!rootOut) {
    throw new WorkspaceWorktreeError(400, "Workspace host mount is not a git repository");
  }

  return safeRealpath(rootOut.trim());
}

export function listWorkspaceWorktrees(
  workspace: Workspace,
  options: ListWorkspaceWorktreesOptions = {},
): WorkspaceWorktree[] {
  const hostMount = workspace.hostMount?.trim();
  if (!hostMount) return [];

  const hostPath = resolveHostPath(hostMount);
  if (!existsSync(hostPath)) return [];

  const workspacePath = safeRealpath(hostPath);
  const rootOut = runGit(workspacePath, ["rev-parse", "--show-toplevel"]);
  if (!rootOut) {
    return withSessionCounts([fallbackMainWorktree(workspacePath, false)], options);
  }

  const workspaceRoot = safeRealpath(rootOut.trim());
  const raw = runGit(workspaceRoot, ["worktree", "list", "--porcelain"]);
  if (!raw) {
    return withSessionCounts([fallbackMainWorktree(workspaceRoot, true)], options);
  }

  const projectManagedRoot = projectManagedWorktreesRoot(workspaceRoot);
  const records = parseWorktreePorcelain(raw);
  const withIds: WorkspaceWorktree[] = records.flatMap((record) => {
    const path = safeRealpath(record.path);
    const isMain = path === workspaceRoot;
    const dataDirWorktreeId = dataDirManagedWorktreeId(options.dataDir, workspace.id, path);
    const isProjectManaged = isPathWithin(projectManagedRoot, path);
    if (!isMain && !dataDirWorktreeId && !isProjectManaged) return [];

    return [
      {
        id: isMain ? MAIN_WORKTREE_ID : (dataDirWorktreeId ?? worktreeIdForPath(path)),
        name: displayNameForWorktree({ ...record, path }, isMain),
        path,
        branch: record.branch,
        headSha: record.headSha?.slice(0, 12) || null,
        isMain,
        isGitRepo: true,
        managedByOppi: Boolean(dataDirWorktreeId),
      } satisfies WorkspaceWorktree,
    ];
  });

  if (!withIds.some((worktree) => worktree.isMain)) {
    withIds.unshift(fallbackMainWorktree(workspaceRoot, true));
  }

  const sorted = withIds.sort((lhs, rhs) => {
    if (lhs.isMain !== rhs.isMain) return lhs.isMain ? -1 : 1;
    if ((lhs.managedByOppi ?? false) !== (rhs.managedByOppi ?? false)) {
      return lhs.managedByOppi ? -1 : 1;
    }
    return lhs.name.localeCompare(rhs.name);
  });
  return withSessionCounts(sorted, options);
}

function withSessionCounts(
  worktrees: WorkspaceWorktree[],
  options: ListWorkspaceWorktreesOptions,
): WorkspaceWorktree[] {
  const counts = options.sessionCountsByWorktreeId;
  if (!counts) return worktrees;
  return worktrees.map((worktree) => ({
    ...worktree,
    sessionCount: counts.get(worktree.id) ?? 0,
  }));
}

function requireBranch(workspaceRoot: string, value: unknown): string {
  if (typeof value !== "string" || !value.trim()) {
    throw new WorkspaceWorktreeError(400, "branch required");
  }
  const branch = value.trim();
  const check = runGitResult(workspaceRoot, ["check-ref-format", "--branch", branch]);
  if (check.status !== 0 || check.stdout.trim() !== branch) {
    throw new WorkspaceWorktreeError(400, "Invalid branch name");
  }
  return branch;
}

function normalizedBase(value: unknown): string {
  if (value === undefined || value === null) return "HEAD";
  if (typeof value !== "string") {
    throw new WorkspaceWorktreeError(400, "base must be a string");
  }
  return value.trim() || "HEAD";
}

function managedCreatePath(
  workspace: Workspace,
  dataDir: string,
  branch: string,
  requestedPath: unknown,
): { id: string; path: string } {
  const root = managedWorktreesRoot(dataDir, workspace.id);
  mkdirSync(root, { recursive: true, mode: 0o700 });

  if (requestedPath !== undefined && requestedPath !== null && typeof requestedPath !== "string") {
    throw new WorkspaceWorktreeError(400, "path must be a string");
  }

  if (typeof requestedPath === "string" && requestedPath.trim()) {
    const path = resolveHostPath(requestedPath);
    if (!isPathWithin(root, path)) {
      throw new WorkspaceWorktreeError(
        400,
        "Worktree path must be under the Oppi-managed data-dir worktrees root",
      );
    }
    const id = directChildName(root, path);
    if (!id || !/^[A-Za-z0-9._-]+$/.test(id)) {
      throw new WorkspaceWorktreeError(
        400,
        "Worktree path must be a direct child with a safe directory name",
      );
    }
    return { id, path };
  }

  const id = worktreeIdForBranch(branch);
  return { id, path: join(root, id) };
}

function branchExists(workspaceRoot: string, branch: string): boolean {
  return runGit(workspaceRoot, ["show-ref", "--verify", `refs/heads/${branch}`]) !== null;
}

function requireAvailableCreateTarget(
  workspace: Workspace,
  targetId: string,
  dataDir: string,
): void {
  if (targetId === MAIN_WORKTREE_ID) {
    throw new WorkspaceWorktreeError(400, "Worktree path uses a reserved worktree id");
  }
  if (listWorkspaceWorktrees(workspace, { dataDir }).some((worktree) => worktree.id === targetId)) {
    throw new WorkspaceWorktreeError(409, "Worktree id already exists");
  }
}

function requireIntegrationMode(value: unknown): WorkspaceWorktreeIntegrationMode {
  if (value === undefined || value === null || value === "") return "merge";
  if (
    typeof value === "string" &&
    INTEGRATION_MODES.has(value as WorkspaceWorktreeIntegrationMode)
  ) {
    return value as WorkspaceWorktreeIntegrationMode;
  }
  throw new WorkspaceWorktreeError(400, "mode must be merge, squash, or ff-only");
}

function requireTargetRef(value: unknown): string {
  if (typeof value !== "string" || !value.trim()) {
    throw new WorkspaceWorktreeError(400, "into target branch required");
  }
  return value.trim();
}

function requireCommit(workspaceRoot: string, ref: string, label: string): string {
  const resolved = runGit(workspaceRoot, ["rev-parse", "--verify", `${ref}^{commit}`])?.trim();
  if (!resolved) {
    throw new WorkspaceWorktreeError(404, `${label} not found`);
  }
  return resolved;
}

function isAncestor(workspaceRoot: string, ancestor: string, descendant: string): boolean {
  return (
    runGitResult(workspaceRoot, ["merge-base", "--is-ancestor", ancestor, descendant]).status === 0
  );
}

function countCommits(workspaceRoot: string, range: string): number {
  const count = Number.parseInt(
    runGit(workspaceRoot, ["rev-list", "--count", range])?.trim() ?? "0",
    10,
  );
  return Number.isFinite(count) ? count : 0;
}

function listPreviewCommits(
  workspaceRoot: string,
  range: string,
): Array<{ sha: string; subject: string }> {
  const raw = runGit(workspaceRoot, ["log", "--oneline", "--no-decorate", "--max-count=50", range]);
  if (!raw) return [];
  return raw
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const [sha = "", ...rest] = line.split(" ");
      return { sha, subject: rest.join(" ").trim() };
    });
}

function parseNameStatus(raw: string): WorkspaceWorktreePreviewFile[] {
  if (!raw) return [];
  return raw
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .flatMap((line) => {
      const parts = line.split("\t");
      const status = parts[0];
      if (!status) return [];
      if ((status.startsWith("R") || status.startsWith("C")) && parts[1] && parts[2]) {
        return [{ status, oldPath: parts[1], path: parts[2] }];
      }
      const path = parts[1];
      return path ? [{ status, path }] : [];
    });
}

function previewChangedFiles(
  workspaceRoot: string,
  targetSha: string,
  sourceSha: string,
): WorkspaceWorktreePreviewFile[] {
  const result = runGitResult(
    workspaceRoot,
    ["diff", "--name-status", `${targetSha}...${sourceSha}`, "--"],
    30_000,
  );
  if (result.status === 0) return parseNameStatus(result.stdout);

  const output = `${result.stderr}\n${result.stdout}`.trim();
  throw new WorkspaceWorktreeError(
    409,
    output ? `Unable to compute changed files: ${output}` : "Unable to compute changed files",
  );
}

function mergeTreeConflictCheck(
  workspaceRoot: string,
  targetSha: string,
  sourceSha: string,
): Pick<WorkspaceWorktreePreview, "conflictCheck" | "conflictCheckError"> {
  const result = runGitResult(
    workspaceRoot,
    ["merge-tree", "--write-tree", targetSha, sourceSha],
    30_000,
  );
  if (result.status === 0) return { conflictCheck: "clean" };

  const output = `${result.stderr}\n${result.stdout}`.trim();
  if (output) return { conflictCheck: "conflicts", conflictCheckError: output };
  return { conflictCheck: "unknown", conflictCheckError: "git merge-tree failed" };
}

export function createWorkspaceWorktree(
  workspace: Workspace,
  request: CreateWorkspaceWorktreeRequest,
  options: WorkspaceWorktreeLifecycleOptions,
): WorkspaceWorktree {
  const workspaceRoot = requireWorkspaceGitRoot(workspace);
  const branch = requireBranch(workspaceRoot, request.branch);
  const base = normalizedBase(request.base);
  const target = managedCreatePath(workspace, options.dataDir, branch, request.path);
  requireAvailableCreateTarget(workspace, target.id, options.dataDir);

  const args = branchExists(workspaceRoot, branch)
    ? ["worktree", "add", target.path, branch]
    : ["worktree", "add", "-b", branch, target.path, base];
  runGitOrThrow(workspaceRoot, args);

  const created = listWorkspaceWorktrees(workspace, { dataDir: options.dataDir }).find(
    (worktree) => worktree.id === target.id,
  );
  if (!created) {
    throw new WorkspaceWorktreeError(500, "Created worktree was not discoverable");
  }
  return created;
}

export function openWorkspaceWorktree(
  workspace: Workspace,
  request: OpenWorkspaceWorktreeRequest,
  options: WorkspaceWorktreeLifecycleOptions,
): WorkspaceWorktree {
  const branch = typeof request.branch === "string" ? request.branch.trim() : "";
  const path = typeof request.path === "string" ? resolveHostPath(request.path) : "";
  if (!branch && !path) {
    throw new WorkspaceWorktreeError(400, "branch or path required");
  }

  const worktrees = listWorkspaceWorktrees(workspace, { dataDir: options.dataDir });
  const worktree = path
    ? worktrees.find((candidate) => safeRealpath(candidate.path) === safeRealpath(path))
    : worktrees.find(
        (candidate) =>
          candidate.id === branch || candidate.name === branch || candidate.branch === branch,
      );

  if (!worktree) {
    throw new WorkspaceWorktreeError(404, "Worktree not found");
  }
  return worktree;
}

export function previewWorkspaceWorktree(
  workspace: Workspace,
  worktreeId: string,
  request: PreviewWorkspaceWorktreeRequest,
  options: WorkspaceWorktreeLifecycleOptions,
): WorkspaceWorktreePreview {
  const workspaceRoot = requireWorkspaceGitRoot(workspace);
  const worktree = resolveWorkspaceWorktree(workspace, worktreeId, { dataDir: options.dataDir });
  if (!worktree) {
    throw new WorkspaceWorktreeError(404, "Worktree not found");
  }
  if (worktree.isMain) {
    throw new WorkspaceWorktreeError(400, "Cannot preview the main checkout as a source worktree");
  }

  const mode = requireIntegrationMode(request.mode);
  const targetRef = requireTargetRef(request.into);
  const sourceSha = requireCommit(worktree.path, "HEAD", "Source worktree HEAD");
  const targetSha = requireCommit(workspaceRoot, targetRef, "Target branch");
  const range = `${targetSha}..${sourceSha}`;
  const alreadyMerged = isAncestor(workspaceRoot, sourceSha, targetSha);
  const fastForwardPossible = isAncestor(workspaceRoot, targetSha, sourceSha);
  const changedFiles = previewChangedFiles(workspaceRoot, targetSha, sourceSha);

  return {
    worktree,
    source: {
      branch: worktree.branch,
      headSha: sourceSha,
    },
    target: {
      ref: targetRef,
      headSha: targetSha,
    },
    mode,
    alreadyMerged,
    fastForwardPossible,
    commitCount: countCommits(workspaceRoot, range),
    commits: listPreviewCommits(workspaceRoot, range),
    changedFiles,
    ...mergeTreeConflictCheck(workspaceRoot, targetSha, sourceSha),
  };
}

export function removeWorkspaceWorktree(
  workspace: Workspace,
  options: RemoveWorkspaceWorktreeOptions,
): WorkspaceWorktree {
  const worktreeId = options.worktreeId.trim();
  if (!worktreeId) {
    throw new WorkspaceWorktreeError(400, "worktree id required");
  }

  const workspaceRoot = requireWorkspaceGitRoot(workspace);
  const worktree = resolveWorkspaceWorktree(workspace, worktreeId, { dataDir: options.dataDir });
  if (!worktree) {
    throw new WorkspaceWorktreeError(404, "Worktree not found");
  }
  if (worktree.isMain) {
    throw new WorkspaceWorktreeError(400, "Cannot remove the main checkout");
  }
  if (!worktree.managedByOppi) {
    throw new WorkspaceWorktreeError(400, "Only Oppi-managed data-dir worktrees can be removed");
  }
  if ((options.activeSessionCount ?? 0) > 0) {
    throw new WorkspaceWorktreeError(409, "Cannot remove a worktree with active sessions");
  }
  if ((options.sessionCount ?? 0) > 0 && options.force !== true) {
    throw new WorkspaceWorktreeError(409, "Worktree has sessions; pass force to remove it");
  }
  if (options.force !== true && isWorktreeDirty(worktree.path)) {
    throw new WorkspaceWorktreeError(409, "Worktree has uncommitted or untracked changes");
  }

  runGitOrThrow(
    workspaceRoot,
    ["worktree", "remove", ...(options.force ? ["--force"] : []), worktree.path],
    409,
  );
  return worktree;
}

function isWorktreeDirty(path: string): boolean {
  return (runGit(path, ["status", "--porcelain=v1"])?.trim().length ?? 0) > 0;
}

export function resolveWorkspaceWorktree(
  workspace: Workspace,
  worktreeId: string | undefined,
  options: Pick<ListWorkspaceWorktreesOptions, "dataDir"> = {},
): WorkspaceWorktree | undefined {
  const requestedId = worktreeId?.trim() || MAIN_WORKTREE_ID;
  return listWorkspaceWorktrees(workspace, options).find((worktree) => worktree.id === requestedId);
}

export function resolveWorkspaceWorktreeForPath(
  workspace: Workspace,
  path: string | undefined,
  options: Pick<ListWorkspaceWorktreesOptions, "dataDir"> = {},
): WorkspaceWorktree | undefined {
  const requestedPath = path?.trim();
  if (!requestedPath) return undefined;

  let best: WorkspaceWorktree | undefined;
  for (const worktree of listWorkspaceWorktrees(workspace, options)) {
    if (!isPathWithin(worktree.path, requestedPath)) continue;
    if (!best || safeRealpath(worktree.path).length > safeRealpath(best.path).length) {
      best = worktree;
    }
  }
  return best;
}

export function normalizeSessionWorktreeId(
  workspace: Workspace,
  requestedWorktreeId: string | undefined,
  options: Pick<ListWorkspaceWorktreesOptions, "dataDir"> = {},
): { worktreeId: string; error?: string } {
  const requestedId = requestedWorktreeId?.trim() || MAIN_WORKTREE_ID;
  if (requestedId === MAIN_WORKTREE_ID && !workspace.hostMount) {
    return { worktreeId: MAIN_WORKTREE_ID };
  }

  const worktree = resolveWorkspaceWorktree(workspace, requestedId, options);
  if (!worktree) {
    return { worktreeId: requestedId, error: "Unknown worktree" };
  }
  return { worktreeId: worktree.id };
}

export function resolveWorkspaceSessionCwd(
  workspace: Workspace,
  worktreeId: string | undefined,
  options: Pick<ListWorkspaceWorktreesOptions, "dataDir"> = {},
): string | undefined {
  const worktree = resolveWorkspaceWorktree(workspace, worktreeId, options);
  return worktree?.path;
}
