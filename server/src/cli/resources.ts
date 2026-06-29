import type { Storage } from "../storage.js";
import { localApiRequest, type LocalApiHostResolvers } from "./local-api-client.js";

export type CliWorkspace = {
  id: string;
  name?: string;
  [key: string]: unknown;
};

export type CliWorktree = {
  id: string;
  name?: string;
  path?: string;
  [key: string]: unknown;
};

export async function listWorkspacesForCli(
  storage: Storage,
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
  storage: Storage,
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
  storage: Storage,
  reference: string,
  hostResolvers: LocalApiHostResolvers = {},
): Promise<string> {
  return (await resolveWorkspaceForCli(storage, reference, hostResolvers)).id;
}

export async function listWorktreesForCli(
  storage: Storage,
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
