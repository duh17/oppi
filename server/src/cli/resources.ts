import { existsSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { resolve, sep } from "node:path";

import {
  localApiRequest,
  type LocalApiConnection,
  type LocalApiHostResolvers,
} from "./local-api-client.js";

export type CliWorkspace = {
  id: string;
  name?: string;
  [key: string]: unknown;
};

export type CliWorktree = {
  id: string;
  name?: string;
  path?: string;
  branch?: string | null;
  managedByOppi?: boolean;
  [key: string]: unknown;
};

export async function listWorkspacesForCli(
  storage: LocalApiConnection,
  hostResolvers: LocalApiHostResolvers = {},
): Promise<CliWorkspace[]> {
  const result = await localApiRequest<{ workspaces?: CliWorkspace[] }>(
    storage,
    "/workspaces",
    undefined,
    hostResolvers,
  );
  return Array.isArray(result.workspaces) ? result.workspaces : [];
}

export async function resolveWorkspaceForCli(
  storage: LocalApiConnection,
  reference: string,
  hostResolvers: LocalApiHostResolvers = {},
): Promise<CliWorkspace> {
  const trimmed = reference.trim();
  if (!trimmed) throw new Error("workspace is required");

  try {
    const direct = await localApiRequest<{ workspace?: CliWorkspace }>(
      storage,
      `/workspaces/${encodeURIComponent(trimmed)}`,
      undefined,
      hostResolvers,
    );
    if (direct.workspace?.id) return direct.workspace;
  } catch (error) {
    if (apiStatus(error) !== 404) throw error;
  }

  const workspaces = await listWorkspacesForCli(storage, hostResolvers);
  const matches = workspaces.filter(
    (workspace) => workspace.id === trimmed || workspace.name === trimmed,
  );
  if (matches.length === 1) return matches[0];
  if (matches.length > 1) throw new Error(`Workspace reference is ambiguous: ${trimmed}`);
  throw notFoundError(`Workspace not found: ${trimmed}`);
}

export async function resolveWorkspaceIdForCli(
  storage: LocalApiConnection,
  reference: string,
  hostResolvers: LocalApiHostResolvers = {},
): Promise<string> {
  return (await resolveWorkspaceForCli(storage, reference, hostResolvers)).id;
}

export async function inferWorkspaceIdFromCwdForCli(
  storage: LocalApiConnection,
  cwd = process.cwd(),
  hostResolvers: LocalApiHostResolvers = {},
): Promise<string | undefined> {
  const currentPath = normalizeWorkspacePath(cwd);
  const workspaces = await listWorkspacesForCli(storage, hostResolvers);
  const workspaceMatches = listWorkspacePathMatches(workspaces, currentPath);
  const worktreeMatches = await listWorkspaceWorktreePathMatches(
    storage,
    workspaces,
    currentPath,
    hostResolvers,
  );
  return inferredWorkspaceIdFromPathMatches(
    [...workspaceMatches, ...worktreeMatches].sort(
      (left, right) => right.root.length - left.root.length,
    ),
  );
}

export async function listWorktreesForCli(
  storage: LocalApiConnection,
  workspaceReference: string,
  hostResolvers: LocalApiHostResolvers = {},
): Promise<{ workspaceId: string; worktrees: CliWorktree[] }> {
  const workspaceId = await resolveWorkspaceIdForCli(storage, workspaceReference, hostResolvers);
  const result = await localApiRequest<{ workspaceId?: string; worktrees?: CliWorktree[] }>(
    storage,
    `/workspaces/${encodeURIComponent(workspaceId)}/worktrees`,
    undefined,
    hostResolvers,
  );
  return {
    workspaceId: result.workspaceId ?? workspaceId,
    worktrees: Array.isArray(result.worktrees) ? result.worktrees : [],
  };
}

export async function createWorktreeForCli(
  storage: LocalApiConnection,
  workspaceReference: string,
  body: { branch: string; base?: string; path?: string },
  hostResolvers: LocalApiHostResolvers = {},
): Promise<{ workspaceId: string; worktree: CliWorktree }> {
  const workspaceId = await resolveWorkspaceIdForCli(storage, workspaceReference, hostResolvers);
  const result = await localApiRequest<{ workspaceId?: string; worktree?: CliWorktree }>(
    storage,
    `/workspaces/${encodeURIComponent(workspaceId)}/worktrees`,
    { method: "POST", body },
    hostResolvers,
  );
  return requireWorktreeResult(result, workspaceId);
}

export async function openWorktreeForCli(
  storage: LocalApiConnection,
  workspaceReference: string,
  body: { branch?: string; path?: string },
  hostResolvers: LocalApiHostResolvers = {},
): Promise<{ workspaceId: string; worktree: CliWorktree }> {
  const workspaceId = await resolveWorkspaceIdForCli(storage, workspaceReference, hostResolvers);
  const result = await localApiRequest<{ workspaceId?: string; worktree?: CliWorktree }>(
    storage,
    `/workspaces/${encodeURIComponent(workspaceId)}/worktrees/open`,
    { method: "POST", body },
    hostResolvers,
  );
  return requireWorktreeResult(result, workspaceId);
}

export async function getWorktreeStatusForCli(
  storage: LocalApiConnection,
  workspaceReference: string,
  worktreeId: string,
  hostResolvers: LocalApiHostResolvers = {},
): Promise<{ workspaceId: string; worktree: CliWorktree; status: unknown }> {
  const workspaceId = await resolveWorkspaceIdForCli(storage, workspaceReference, hostResolvers);
  const result = await localApiRequest<{
    workspaceId?: string;
    worktree?: CliWorktree;
    status?: unknown;
  }>(
    storage,
    `/workspaces/${encodeURIComponent(workspaceId)}/worktrees/${encodeURIComponent(worktreeId)}/status`,
    undefined,
    hostResolvers,
  );
  if (!result.worktree?.id) throw new Error("Local API did not return a worktree");
  return {
    workspaceId: result.workspaceId ?? workspaceId,
    worktree: result.worktree,
    status: result.status,
  };
}

export async function previewWorktreeForCli(
  storage: LocalApiConnection,
  workspaceReference: string,
  worktreeId: string,
  body: { into: string; mode?: string },
  hostResolvers: LocalApiHostResolvers = {},
): Promise<{ workspaceId: string; preview: unknown }> {
  const workspaceId = await resolveWorkspaceIdForCli(storage, workspaceReference, hostResolvers);
  const result = await localApiRequest<{ workspaceId?: string; preview?: unknown }>(
    storage,
    `/workspaces/${encodeURIComponent(workspaceId)}/worktrees/${encodeURIComponent(worktreeId)}/preview`,
    { method: "POST", body },
    hostResolvers,
  );
  if (!result.preview) throw new Error("Local API did not return a worktree preview");
  return { workspaceId: result.workspaceId ?? workspaceId, preview: result.preview };
}

export async function removeWorktreeForCli(
  storage: LocalApiConnection,
  workspaceReference: string,
  worktreeId: string,
  force: boolean,
  hostResolvers: LocalApiHostResolvers = {},
): Promise<{ workspaceId: string; worktree: CliWorktree }> {
  const workspaceId = await resolveWorkspaceIdForCli(storage, workspaceReference, hostResolvers);
  const suffix = force ? "?force=true" : "";
  const result = await localApiRequest<{ workspaceId?: string; worktree?: CliWorktree }>(
    storage,
    `/workspaces/${encodeURIComponent(workspaceId)}/worktrees/${encodeURIComponent(worktreeId)}${suffix}`,
    { method: "DELETE" },
    hostResolvers,
  );
  return requireWorktreeResult(result, workspaceId);
}

function requireWorktreeResult(
  result: { workspaceId?: string; worktree?: CliWorktree },
  workspaceId: string,
): { workspaceId: string; worktree: CliWorktree } {
  if (!result.worktree?.id) throw new Error("Local API did not return a worktree");
  return { workspaceId: result.workspaceId ?? workspaceId, worktree: result.worktree };
}

type WorkspacePathMatch = { workspace: CliWorkspace; root: string };

function inferredWorkspaceIdFromPathMatches(matches: WorkspacePathMatch[]): string | undefined {
  const uniqueMatches = dedupeWorkspacePathMatches(matches);
  if (uniqueMatches.length === 0) return undefined;
  if (
    uniqueMatches.length > 1 &&
    uniqueMatches[0]?.root.length === uniqueMatches[1]?.root.length &&
    uniqueMatches[0]?.workspace.id !== uniqueMatches[1]?.workspace.id
  ) {
    throw new Error("Workspace inference is ambiguous; pass --workspace or --all");
  }
  return uniqueMatches[0]?.workspace.id;
}

function dedupeWorkspacePathMatches(matches: WorkspacePathMatch[]): WorkspacePathMatch[] {
  const seen = new Set<string>();
  return matches.filter((match) => {
    const key = `${match.workspace.id}\0${match.root}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

async function listWorkspaceWorktreePathMatches(
  storage: LocalApiConnection,
  workspaces: CliWorkspace[],
  currentPath: string,
  hostResolvers: LocalApiHostResolvers,
): Promise<WorkspacePathMatch[]> {
  const matches: WorkspacePathMatch[] = [];
  for (const workspace of workspaces) {
    const result = await localApiRequest<{ worktrees?: CliWorktree[] }>(
      storage,
      `/workspaces/${encodeURIComponent(workspace.id)}/worktrees`,
      undefined,
      hostResolvers,
    );
    for (const worktree of result.worktrees ?? []) {
      if (!worktree.path) continue;
      const root = normalizeWorkspacePath(worktree.path);
      if (isPathWithin(root, currentPath)) matches.push({ workspace, root });
    }
  }
  return matches.sort((left, right) => right.root.length - left.root.length);
}

function listWorkspacePathMatches(
  workspaces: CliWorkspace[],
  currentPath: string,
): WorkspacePathMatch[] {
  return workspaces
    .flatMap((workspace) => {
      const hostMount = typeof workspace.hostMount === "string" ? workspace.hostMount : undefined;
      if (!hostMount) return [];
      const root = normalizeWorkspacePath(hostMount);
      return isPathWithin(root, currentPath) ? [{ workspace, root }] : [];
    })
    .sort((left, right) => right.root.length - left.root.length);
}

function normalizeWorkspacePath(path: string): string {
  const expanded = path.startsWith(`~${sep}`) ? resolve(homedir(), path.slice(2)) : resolve(path);
  return existsSync(expanded) ? realpathSync(expanded) : expanded;
}

function isPathWithin(root: string, candidate: string): boolean {
  return candidate === root || candidate.startsWith(root.endsWith(sep) ? root : `${root}${sep}`);
}

export function apiStatus(error: unknown): number | undefined {
  return typeof (error as { status?: unknown }).status === "number"
    ? (error as { status: number }).status
    : undefined;
}

function notFoundError(message: string): Error & { status: number } {
  const error = new Error(message) as Error & { status: number };
  error.status = 404;
  return error;
}
