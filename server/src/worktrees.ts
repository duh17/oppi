import { execFileSync } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import { basename, sep, resolve } from "node:path";

import { resolveHostPath } from "./host.js";
import type { Workspace, WorkspaceWorktree } from "./types.js";

const MAIN_WORKTREE_ID = "main";
const OPPI_WORKTREES_DIR = ".pi/worktrees";

type WorktreePorcelainRecord = {
  path: string;
  headSha: string | null;
  branch: string | null;
};

function safeRealpath(path: string): string {
  try {
    return realpathSync(resolve(path));
  } catch {
    return resolve(path);
  }
}

function runGit(cwd: string, args: string[]): string | null {
  try {
    return execFileSync("git", args, {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 5000,
    });
  } catch {
    return null;
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

function isPathWithin(parent: string, child: string): boolean {
  const resolvedParent = safeRealpath(parent);
  const resolvedChild = safeRealpath(child);
  return resolvedChild === resolvedParent || resolvedChild.startsWith(`${resolvedParent}${sep}`);
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
  };
}

export function listWorkspaceWorktrees(workspace: Workspace): WorkspaceWorktree[] {
  const hostMount = workspace.hostMount?.trim();
  if (!hostMount) return [];

  const hostPath = resolveHostPath(hostMount);
  if (!existsSync(hostPath)) return [];

  const workspacePath = safeRealpath(hostPath);
  const rootOut = runGit(workspacePath, ["rev-parse", "--show-toplevel"]);
  if (!rootOut) {
    return [fallbackMainWorktree(workspacePath, false)];
  }

  const workspaceRoot = safeRealpath(rootOut.trim());
  const raw = runGit(workspaceRoot, ["worktree", "list", "--porcelain"]);
  if (!raw) {
    return [fallbackMainWorktree(workspaceRoot, true)];
  }

  const managedRoot = resolve(workspaceRoot, OPPI_WORKTREES_DIR);
  const records = parseWorktreePorcelain(raw);
  const withIds: WorkspaceWorktree[] = records.flatMap((record) => {
    const path = safeRealpath(record.path);
    const isMain = path === workspaceRoot;
    if (!isMain && !isPathWithin(managedRoot, path)) return [];

    return [
      {
        id: isMain ? MAIN_WORKTREE_ID : worktreeIdForPath(path),
        name: displayNameForWorktree({ ...record, path }, isMain),
        path,
        branch: record.branch,
        headSha: record.headSha?.slice(0, 12) || null,
        isMain,
        isGitRepo: true,
      } satisfies WorkspaceWorktree,
    ];
  });

  if (!withIds.some((worktree) => worktree.isMain)) {
    withIds.unshift(fallbackMainWorktree(workspaceRoot, true));
  }

  return withIds.sort((lhs, rhs) => {
    if (lhs.isMain !== rhs.isMain) return lhs.isMain ? -1 : 1;
    return lhs.name.localeCompare(rhs.name);
  });
}

export function resolveWorkspaceWorktree(
  workspace: Workspace,
  worktreeId: string | undefined,
): WorkspaceWorktree | undefined {
  const requestedId = worktreeId?.trim() || MAIN_WORKTREE_ID;
  return listWorkspaceWorktrees(workspace).find((worktree) => worktree.id === requestedId);
}

export function normalizeSessionWorktreeId(
  workspace: Workspace,
  requestedWorktreeId: string | undefined,
): { worktreeId: string; error?: string } {
  const requestedId = requestedWorktreeId?.trim() || MAIN_WORKTREE_ID;
  if (requestedId === MAIN_WORKTREE_ID && !workspace.hostMount) {
    return { worktreeId: MAIN_WORKTREE_ID };
  }

  const worktree = resolveWorkspaceWorktree(workspace, requestedId);
  if (!worktree) {
    return { worktreeId: requestedId, error: "Unknown worktree" };
  }
  return { worktreeId: worktree.id };
}

export function resolveWorkspaceSessionCwd(
  workspace: Workspace,
  worktreeId: string | undefined,
): string | undefined {
  const worktree = resolveWorkspaceWorktree(workspace, worktreeId);
  return worktree?.path;
}
