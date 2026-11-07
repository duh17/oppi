/**
 * Which origin edits a file: decided by where the file *is* after symlinks,
 * never by how the reader reached it. A chat link, an Org `file:` link, a
 * session-touched path, and the workspace tree all name one canonical file, so
 * they all get the same answer and write through the same origin.
 *
 * The owner is the narrowest one that names the file:
 *
 * 1. Pi's own allowlisted agent files (`origin=pi`): a list of files.
 * 2. An editable Skill's directory, or a Markdown Skill's one file (`origin=skill`).
 * 3. The deepest workspace checkout that contains it: a worktree, or the
 *    workspace mount (`origin=workspace`, with `worktreeId` for a worktree).
 * 4. Anything else under the server account's home (`origin=host`), unless
 *    `hostEditRefusal` names it: credentials, keys, Oppi's and Pi's own
 *    directories, and git internals.
 *
 * A read through a sandbox workspace (its own origin, or a sandbox session's)
 * is confined: its only owner is that workspace, so a sandbox context can never
 * name a host file as editable. Every authenticated caller is the owner (the
 * local owner token or a paired device), and both can already run agents on
 * the host; the refusal list keeps a followed link from making a secret or a
 * file that runs code one tap away from a write.
 */

import { realpathSync } from "node:fs";
import { lstat } from "node:fs/promises";
import { homedir } from "node:os";
import { join, relative, resolve, sep } from "node:path";

import { isWorkspaceEditorTextPath } from "./file-serving-policy.js";
import { isPathWithinRoot } from "./path-utils.js";
import { piAgentCreatesIn, piAgentEditablePath } from "./pi-agent-files.js";
import { workspaceMountRoot } from "./session-work-root.js";
import type { Workspace } from "./types.js";
import type { FileEditTarget } from "./workspace-file-edit.js";
import { managedWorktreesRoot, resolveWorkspaceWorktreeForPath } from "./worktrees.js";

/** Response header naming the origin a file is edited through, as a `/files/current` query. */
export const FILE_EDIT_ORIGIN_HEADER = "X-Oppi-Edit-Origin";
/** Response header saying why a file is read-only: a `FileEditRefusal`. */
export const FILE_EDIT_REFUSAL_HEADER = "X-Oppi-Edit-Refusal";
/** Request header asking a `/files/current` read to name the file's edit origin. */
export const FILE_EDIT_RESOLVE_HEADER = "x-oppi-edit-resolve";

export type FileEditOwner =
  | { kind: "pi"; agentDir: string; path: string }
  | { kind: "skill"; skillId: string; root: string; path: string }
  | { kind: "workspace"; workspace: Workspace; worktreeId?: string; root: string; path: string }
  /** `root` is the real home; `path` the file's canonical absolute path. */
  | { kind: "host"; root: string; path: string };

/**
 * Why a file has no editor:
 * - `type`: not an editor text type.
 * - `outside-home`: outside every owner and outside the home directory.
 * - `protected`: a host file on the refusal list.
 * - `ineligible`: the name the reader followed is itself a symlink, or the
 *   owner's editor contract refuses the file (size, encoding).
 */
export type FileEditRefusal = "type" | "outside-home" | "protected" | "ineligible";

export type FileEditOwnerResult =
  { kind: "owner"; owner: FileEditOwner } | { kind: "refused"; reason: FileEditRefusal };

export interface FileEditOwnerSources {
  workspaces: () => Workspace[];
  dataDir: string;
  /** Pi's agent directory, or null when it cannot be read. */
  agentDir: () => string | null;
  homeDir?: string;
  editableSkillContaining: (
    realPath: string,
  ) => Promise<{ skillId: string; root: string; path: string } | null>;
}

/** The sandbox workspace a read went through; its mount is the only owner. */
export interface FileEditConfinement {
  workspace: Workspace;
  root: string;
}

/**
 * Directories and files under the home that never edit as host files, matched
 * home-relative and case-folded (macOS volumes are usually case-insensitive).
 * The same secret set the sandbox hides from its mount, plus credential stores,
 * keychains, login items, and Oppi's and Pi's own state.
 */
const PROTECTED_HOME_PATHS = [
  ".ssh",
  ".aws",
  ".azure",
  ".gnupg",
  ".kube",
  ".docker",
  ".pi",
  ".password-store",
  ".git-credentials",
  ".netrc",
  ".npmrc",
  ".pypirc",
  ".pgpass",
  ".config/gh",
  ".config/gcloud",
  ".config/op",
  ".config/oppi",
  ".local/share/keyrings",
  "library/keychains",
  "library/launchagents",
];

/** Directory names refused anywhere in the path. */
const PROTECTED_SEGMENTS = new Set([".ssh", ".gnupg", ".aws", ".git"]);

/** File names refused anywhere: env files, token stores, and key material. */
const PROTECTED_FILE_NAME =
  /^(?:\.env(?:\..*)?|\.envrc|auth\.json|credentials(?:\.[a-z0-9]+)?|secrets?\.[a-z0-9]+|.*\.(?:pem|key|p12|pfx))$/;

/** Canonical roots refused as host files besides the fixed list. */
export interface ProtectedRoots {
  home: string;
  dataDir: string | null;
  agentDir: string | null;
}

/**
 * Whether a path under the home is on the refusal list. Asked about the
 * lexical path the request named and again about the canonical path after
 * symlinks, so neither a protected name nor a link into a protected place
 * edits.
 */
export function isProtectedHostPath(absolutePath: string, roots: ProtectedRoots): boolean {
  for (const root of [roots.dataDir, roots.agentDir]) {
    if (root && isPathWithinRoot(absolutePath, root)) return true;
  }
  const rel = relative(roots.home, absolutePath).split(sep).join("/").toLowerCase();
  for (const protectedPath of PROTECTED_HOME_PATHS) {
    if (rel === protectedPath || rel.startsWith(`${protectedPath}/`)) return true;
  }
  const segments = rel.split("/");
  if (segments.some((segment) => PROTECTED_SEGMENTS.has(segment))) return true;
  return PROTECTED_FILE_NAME.test(segments[segments.length - 1] ?? "");
}

function realpathOrNull(path: string): string | null {
  try {
    return realpathSync(path);
  } catch {
    return null;
  }
}

/** The real home and the real directories the refusal list adds to it. */
export function protectedRoots(
  sources: Pick<FileEditOwnerSources, "homeDir" | "dataDir" | "agentDir">,
): ProtectedRoots | null {
  let home: string | null;
  try {
    home = realpathOrNull(resolve(sources.homeDir ?? homedir()));
  } catch {
    home = null;
  }
  if (!home) return null;
  const agentDir = agentDirOrNull(sources);
  return {
    home,
    dataDir: realpathOrNull(sources.dataDir),
    agentDir: agentDir ? realpathOrNull(agentDir) : null,
  };
}

/** Pi's agent directory, or null when it cannot be read. */
function agentDirOrNull(sources: Pick<FileEditOwnerSources, "agentDir">): string | null {
  try {
    return sources.agentDir();
  } catch {
    return null;
  }
}

function toPosix(path: string): string {
  return path.split(sep).join("/");
}

/** The deepest checkout of any workspace that holds `realPath`. */
async function workspaceOwner(
  realPath: string,
  sources: FileEditOwnerSources,
): Promise<Extract<FileEditOwner, { kind: "workspace" }> | null> {
  type Candidate = { owner: Extract<FileEditOwner, { kind: "workspace" }>; realRoot: string };
  const candidates: Candidate[] = [];
  for (const workspace of sources.workspaces()) {
    const mount = workspaceMountRoot(workspace, { create: false });
    const realMount = realpathOrNull(mount);
    const inMount =
      realMount !== null && realPath !== realMount && isPathWithinRoot(realPath, realMount);
    if (inMount) {
      candidates.push({
        owner: {
          kind: "workspace",
          workspace,
          root: mount,
          path: toPosix(relative(realMount, realPath)),
        },
        realRoot: realMount,
      });
    }
    // A sandbox lists only its mount; a host workspace's worktrees live under
    // the data directory or inside its mount, so only those workspaces pay
    // for a `git worktree list`.
    if (workspace.runtime === "sandbox") continue;
    const managed = realpathOrNull(managedWorktreesRoot(sources.dataDir, workspace.id));
    const inManaged = managed !== null && isPathWithinRoot(realPath, managed);
    if (!inMount && !inManaged) continue;
    const worktree = await resolveWorkspaceWorktreeForPath(workspace, realPath, {
      dataDir: sources.dataDir,
    });
    if (!worktree || worktree.isMain) continue;
    const realWorktree = realpathOrNull(worktree.path);
    if (!realWorktree || realPath === realWorktree || !isPathWithinRoot(realPath, realWorktree)) {
      continue;
    }
    candidates.push({
      owner: {
        kind: "workspace",
        workspace,
        worktreeId: worktree.id,
        root: worktree.path,
        path: toPosix(relative(realWorktree, realPath)),
      },
      realRoot: realWorktree,
    });
  }
  // Deepest root first; two workspaces on one directory resolve by id, so the
  // answer never depends on which one the reader came from.
  candidates.sort(
    (a, b) =>
      b.realRoot.length - a.realRoot.length ||
      a.owner.workspace.id.localeCompare(b.owner.workspace.id) ||
      (a.owner.worktreeId ?? "").localeCompare(b.owner.worktreeId ?? ""),
  );
  return candidates[0]?.owner ?? null;
}

/**
 * The origin that edits the canonical file `realPath`. `lexicalPath` is the
 * name the request used before symlinks; a host file is refused when either
 * name is protected.
 */
export async function resolveFileEditOwner(input: {
  realPath: string;
  lexicalPath: string;
  sources: FileEditOwnerSources;
  confinement?: FileEditConfinement;
}): Promise<FileEditOwnerResult> {
  const { realPath, sources } = input;
  if (!isWorkspaceEditorTextPath(realPath)) return { kind: "refused", reason: "type" };
  // A link's own name never edits, whatever it points at: the editor contract
  // refuses a final-component symlink on every origin, so a dotfile-managed
  // `SYSTEM.md` stays read-only through Pi and through any link to it. Folder
  // links on the way are followed; the canonical checks below judge where
  // they lead.
  try {
    if ((await lstat(input.lexicalPath)).isSymbolicLink()) {
      return { kind: "refused", reason: "ineligible" };
    }
  } catch {
    return { kind: "refused", reason: "ineligible" };
  }

  if (input.confinement) {
    // Sandbox context: the mount or nothing. The read already refused a path
    // outside it, so this is the same boundary stated again.
    const realRoot = realpathOrNull(input.confinement.root);
    if (!realRoot || realPath === realRoot || !isPathWithinRoot(realPath, realRoot)) {
      return { kind: "refused", reason: "outside-home" };
    }
    return {
      kind: "owner",
      owner: {
        kind: "workspace",
        workspace: input.confinement.workspace,
        root: input.confinement.root,
        path: toPosix(relative(realRoot, realPath)),
      },
    };
  }

  const agentDir = agentDirOrNull(sources);
  const realAgentDir = agentDir ? realpathOrNull(agentDir) : null;
  if (agentDir && realAgentDir && isPathWithinRoot(realPath, realAgentDir)) {
    const path = piAgentEditablePath(toPosix(relative(realAgentDir, realPath)));
    if (path) return { kind: "owner", owner: { kind: "pi", agentDir, path } };
  }

  const skill = await sources.editableSkillContaining(realPath);
  if (skill) return { kind: "owner", owner: { kind: "skill", ...skill } };

  const workspace = await workspaceOwner(realPath, sources);
  if (workspace) return { kind: "owner", owner: workspace };

  const roots = protectedRoots(sources);
  if (!roots || realPath === roots.home || !isPathWithinRoot(realPath, roots.home)) {
    return { kind: "refused", reason: "outside-home" };
  }
  if (
    isProtectedHostPath(realPath, roots) ||
    (isPathWithinRoot(input.lexicalPath, roots.home) &&
      isProtectedHostPath(input.lexicalPath, roots))
  ) {
    return { kind: "refused", reason: "protected" };
  }
  return { kind: "owner", owner: { kind: "host", root: roots.home, path: realPath } };
}

/** The `/files/current` query that edits through `owner`. */
export function fileEditOriginQuery(owner: FileEditOwner): string {
  const params = new URLSearchParams({ origin: owner.kind });
  switch (owner.kind) {
    case "workspace":
      params.set("workspaceId", owner.workspace.id);
      if (owner.worktreeId) params.set("worktreeId", owner.worktreeId);
      break;
    case "skill":
      params.set("skillId", owner.skillId);
      break;
    case "pi":
    case "host":
      break;
  }
  params.set("path", owner.path);
  return params.toString();
}

/**
 * The editor contract's target for an owner. A host file is checked against
 * the refusal list again on every inspection, after symlinks, so a link
 * swapped in after the owner was chosen cannot widen what is written.
 */
export function fileEditTargetForOwner(
  owner: FileEditOwner,
  roots?: ProtectedRoots,
): FileEditTarget | null {
  switch (owner.kind) {
    case "workspace":
      return { workspace: owner.workspace, root: owner.root, requestedPath: owner.path };
    case "skill":
      return { root: owner.root, requestedPath: owner.path };
    case "pi":
      return piFileEditTarget(owner.agentDir, owner.path);
    case "host": {
      if (!roots) return null;
      return hostFileEditTarget(roots, owner.path);
    }
  }
}

/** Pi's agent directory: the allowlist again after symlinks, and the one place a file is created. */
export function piFileEditTarget(agentDir: string, path: string): FileEditTarget {
  return {
    root: agentDir,
    requestedPath: path,
    // The allowlist again, on the path after symlinks: a link inside the
    // agent directory must not reach a file the list does not name. This is
    // also where a *linked* Pi file stays read-only — `inspectFileForEdit`
    // refuses a final-component symlink and the canonical recheck refuses a
    // link that leads elsewhere.
    allowsCanonical: (relativeToRealRoot) => piAgentEditablePath(relativeToRealRoot) !== null,
    // A missing file the editor may create: the same allowlist, plus the one
    // directory it may appear in. `inspectFileForEdit` still proves that
    // directory is the real one and refuses a link, so a `prompts` symlink
    // creates nothing.
    createsIn: (parentRelativeToRealRoot) => piAgentCreatesIn(parentRelativeToRealRoot),
  };
}

/**
 * A host file by absolute path: the root is the real home, so the editor's
 * containment, final-symlink, and canonical rechecks all run against it.
 * Null for a path outside the home.
 */
export function hostFileEditTarget(
  roots: ProtectedRoots,
  absolutePath: string,
): FileEditTarget | null {
  const resolved = resolve(absolutePath);
  if (resolved === roots.home || !isPathWithinRoot(resolved, roots.home)) return null;
  return {
    root: roots.home,
    requestedPath: toPosix(relative(roots.home, resolved)),
    allowsCanonical: (relativeToRealRoot) =>
      !isProtectedHostPath(join(roots.home, relativeToRealRoot), roots),
  };
}
