import { existsSync, mkdirSync } from "node:fs";
import { lstat, stat } from "node:fs/promises";
import { join } from "node:path";

import { isControlConversation, isControlRouteSession } from "./control-session.js";
import { resolveHostPath } from "./host.js";
import { ensureOwnerOnlyRealDirectory } from "./owner-directory.js";
import type { Session, Workspace } from "./types.js";
import { resolveWorkspaceSessionCwd, WorkspaceWorktreeError } from "./worktrees.js";

/**
 * One owner for "which directory on this host belongs to this session".
 *
 * Kinds of session:
 * - workspace session: the workspace's stored host mount, or its host
 *   worktree when `worktreeId` names one (sandbox mounts have no worktrees).
 *   Sandbox confinement is not decided here: the result carries the
 *   `workspace`, and `workspace.runtime === "sandbox"` is the one signal that
 *   current-file resolution confines reads to the mount.
 * - control-route session (declared Pi Control, or the durable control
 *   conversation): a server-owned owner-only directory under the data dir.
 * - any other workspace-less session: no directory (`no-workspace`).
 *
 * `create: false` never touches the filesystem except to look (reads, cleanup).
 * `create: true` is for session start and attachment writes: it makes the
 * control directories and a sandbox's backing folder.
 *
 * Failure rule (one for every caller): expected unavailability comes back as a
 * result kind; unexpected failures (permissions, git crashing) throw. A caller
 * that wants the legacy throw rethrows `error` / `message` itself.
 */
export interface SessionWorkRootStore {
  getWorkspace(workspaceId: string): Workspace | undefined;
  getDataDir(): string;
}

type WorkRootSession = Pick<Session, "workspaceId" | "worktreeId" | "control" | "serverDurable">;

export type SessionWorkRoot =
  | {
      kind: "ok";
      root: string;
      /** Present for workspace sessions, absent for control-route sessions. */
      workspace?: Workspace;
    }
  /** Workspace-less and not a control-route session. */
  | { kind: "no-workspace" }
  /** The session names a workspace that no longer exists. */
  | { kind: "workspace-missing" }
  /** The session's host worktree is gone or cannot be resolved. */
  | { kind: "worktree-unavailable"; error: WorkspaceWorktreeError }
  /** A control directory is a symlink or not a directory; never followed. */
  | { kind: "invalid-root"; message: string }
  /** `create: false` only: the directory does not exist. */
  | { kind: "root-missing" };

/** `create: true` makes missing directories, so it never reports `root-missing`. */
export type CreatedSessionWorkRoot = Exclude<SessionWorkRoot, { kind: "root-missing" }>;

export function sessionWorkRoot(
  session: WorkRootSession,
  store: SessionWorkRootStore,
  options: { create: true },
): Promise<CreatedSessionWorkRoot>;
export function sessionWorkRoot(
  session: WorkRootSession,
  store: SessionWorkRootStore,
  options: { create: boolean },
): Promise<SessionWorkRoot>;
export function sessionWorkRoot(
  session: WorkRootSession,
  store: SessionWorkRootStore,
  options: { create: boolean },
): Promise<SessionWorkRoot> {
  const workspace = session.workspaceId ? store.getWorkspace(session.workspaceId) : undefined;
  return resolveSessionWorkRoot(session, workspace, store.getDataDir(), options);
}

/**
 * Same rule for a caller that already holds the workspace (session start).
 * `dataDir` is required only for control-route sessions and worktrees.
 */
export function resolveSessionWorkRoot(
  session: WorkRootSession,
  workspace: Workspace | undefined,
  dataDir: string | undefined,
  options: { create: true },
): Promise<CreatedSessionWorkRoot>;
export function resolveSessionWorkRoot(
  session: WorkRootSession,
  workspace: Workspace | undefined,
  dataDir: string | undefined,
  options: { create: boolean },
): Promise<SessionWorkRoot>;
export async function resolveSessionWorkRoot(
  session: WorkRootSession,
  workspace: Workspace | undefined,
  dataDir: string | undefined,
  { create }: { create: boolean },
): Promise<SessionWorkRoot> {
  if (isControlRouteSession(session)) {
    return controlRoot(isControlConversation(session), dataDir, create);
  }
  if (!workspace) {
    return session.workspaceId ? { kind: "workspace-missing" } : { kind: "no-workspace" };
  }

  if (workspace.runtime !== "sandbox" && session.worktreeId) {
    try {
      const worktreePath = await resolveWorkspaceSessionCwd(workspace, session.worktreeId, {
        dataDir,
      });
      if (worktreePath && existsSync(worktreePath)) {
        return { kind: "ok", root: worktreePath, workspace };
      }
    } catch (error: unknown) {
      if (error instanceof WorkspaceWorktreeError) return { kind: "worktree-unavailable", error };
      throw error;
    }
    return {
      kind: "worktree-unavailable",
      error: new WorkspaceWorktreeError(409, "Session worktree is no longer available"),
    };
  }

  const root = workspaceMountRoot(workspace, { create });
  if (!create && !(await pathExists(root))) return { kind: "root-missing" };
  return { kind: "ok", root, workspace };
}

/**
 * Host path of a workspace mount. `create` makes a sandbox's backing folder:
 * the host path only backs the VM mount, so an empty-folder sandbox gets its
 * real directory lazily on first use.
 */
export function workspaceMountRoot(workspace: Workspace, { create }: { create: boolean }): string {
  const root = resolveHostPath(workspace.hostMount);
  if (create && workspace.runtime === "sandbox") mkdirSync(root, { recursive: true });
  return root;
}

/**
 * Attachment root for a session: null when the session cannot take
 * attachments, a throw when its worktree or control directory is broken.
 */
export async function attachmentWorkRoot(
  session: WorkRootSession,
  store: SessionWorkRootStore,
): Promise<string | null> {
  const result = await sessionWorkRoot(session, store, { create: true });
  switch (result.kind) {
    case "ok":
      return result.root;
    case "worktree-unavailable":
      throw result.error;
    case "invalid-root":
      throw new Error(result.message);
    case "no-workspace":
    case "workspace-missing":
      return null;
  }
}

type DirectoryState = "real" | "missing" | "invalid";

async function inspectDirectory(path: string): Promise<DirectoryState> {
  try {
    const stats = await lstat(path);
    return stats.isSymbolicLink() || !stats.isDirectory() ? "invalid" : "real";
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException | undefined)?.code === "ENOENT") return "missing";
    throw error;
  }
}

async function controlRoot(
  conversation: boolean,
  dataDir: string | undefined,
  create: boolean,
): Promise<SessionWorkRoot> {
  const label = conversation ? "Control conversation" : "Control session";
  if (!dataDir) {
    throw new Error(
      conversation
        ? "The control conversation requires an Oppi data directory"
        : "Control sessions require an Oppi data directory",
    );
  }
  const parent = join(dataDir, conversation ? "control-conversation" : "control-sessions");
  const root = join(parent, "cwd");
  const levels: Array<[path: string, message: string]> = [
    [parent, `${label} cwd parent must be a real directory`],
    [root, `${label} cwd must be a real directory`],
  ];
  for (const [path, message] of levels) {
    const state = await inspectDirectory(path);
    if (state === "invalid") return { kind: "invalid-root", message };
    if (create) ensureOwnerOnlyRealDirectory(path, message);
    else if (state === "missing") return { kind: "root-missing" };
  }
  return { kind: "ok", root };
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException | undefined)?.code === "ENOENT") return false;
    throw error;
  }
}
