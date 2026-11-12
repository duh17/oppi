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
 * name a host file as editable. A host-context path that passes through a link
 * inside a sandbox mount is confined the same way: the guest writes its mount,
 * so a link it planted there never leads to an editable file outside it.
 *
 * Every authenticated caller is the owner (the local owner token or a paired
 * device), and both can already run agents on the host, so the refusal list is
 * not a boundary against the caller. It keeps a followed link from making a
 * secret, or a file that runs code or decides who may run it, one tap away
 * from a write: credentials, shell startup, programs on the PATH and the
 * packages they load, tools that run commands from their config, `~/Library`,
 * executables, and hard-linked files. A deny list cannot name every file that
 * some program executes; it names the places where that is what the file is for.
 */

import { lstat, readlink } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

import { isWorkspaceEditorTextPath } from "./file-serving-policy.js";
import { LAYOUT_FILE_NAME, LAYOUTS_FOLDER } from "./layout-validation.js";
import { canonicalRealPath, isPathWithinRoot } from "./path-utils.js";
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
 * - `outside-home`: outside every owner and outside the home directory, or
 *   outside the sandbox the read went through.
 * - `protected`: a host file on the refusal list, or a read-only Skill's file.
 * - `ineligible`: the name the reader followed is itself a symlink, or the
 *   owner's editor contract refuses the file (size, encoding, an executable or
 *   hard-linked host file).
 * - `disabled`: a home file no narrower origin owns, on a server whose owner
 *   turned host-file editing off (`fileEditing.hostFiles: false`).
 */
export type FileEditRefusal = "type" | "outside-home" | "protected" | "ineligible" | "disabled";

export type FileEditOwnerResult =
  { kind: "owner"; owner: FileEditOwner } | { kind: "refused"; reason: FileEditRefusal };

export interface FileEditOwnerSources {
  workspaces: () => Workspace[];
  dataDir: string;
  /** Pi's agent directory, or null when it cannot be read. */
  agentDir: () => string | null;
  homeDir?: string;
  /** Whether a home file no narrower origin owns edits at all (default on). */
  hostFilesEnabled?: () => boolean;
  /** The deepest Skill that owns `realPath`; a read-only one keeps it read-only. */
  skillContaining: (
    realPath: string,
  ) => Promise<{ skillId: string; root: string; path: string; editable: boolean } | null>;
}

/** The sandbox workspace a read went through; its mount is the only owner. */
export interface FileEditConfinement {
  workspace: Workspace;
  root: string;
}

/**
 * Directories and files under the home that never edit as host files, matched
 * home-relative and case-folded (macOS volumes are usually case-insensitive).
 * Only editor text types reach this list (`isWorkspaceEditorTextPath`), so
 * extensionless dotfiles such as `.zshrc` and `.gitconfig` are already
 * read-only; these are the places where a `.json`, `.toml`, `.sh`, `.py`, or
 * `.js` file is a credential, or runs code the next time something starts.
 */
const PROTECTED_HOME_PATHS = [
  // Credentials, keys, and token stores (the set the sandbox hides, and more).
  ".ssh",
  ".aws",
  ".azure",
  ".gnupg",
  ".kube",
  ".docker",
  ".password-store",
  ".git-credentials",
  ".netrc",
  ".npmrc",
  ".pypirc",
  ".pgpass",
  ".config/gh",
  ".config/gcloud",
  ".config/op",
  ".local/share/keyrings",
  // Oppi's and Pi's own state: auth, config, extensions, packages.
  ".pi",
  ".config/oppi",
  // Shell startup: sourced by every new shell.
  ".config/fish",
  ".config/zsh",
  ".oh-my-zsh",
  ".zsh",
  // Programs on the PATH, and the toolchains and packages they load.
  "bin",
  ".bin",
  ".local/bin",
  ".local/lib",
  ".local/pipx",
  ".local/share/uv",
  ".local/share/mise",
  ".bun",
  ".bunfig.toml",
  ".config/.bunfig.toml",
  ".deno",
  ".nvm",
  ".volta",
  ".npm",
  ".npm-global",
  ".cargo",
  ".rustup",
  ".pyenv",
  ".rbenv",
  ".gem",
  ".asdf",
  "go/bin",
  "go/pkg",
  // Tools that run commands from their config: agent hooks and MCP servers,
  // editor extensions and init files, automation, git's global config.
  ".claude",
  ".claude.json",
  ".codex",
  ".cursor",
  ".gemini",
  ".vscode",
  ".vscode-server",
  ".config/zed",
  ".config/nvim",
  ".vim",
  ".hammerspoon",
  ".config/karabiner",
  ".config/git",
  ".ipython",
  // App state, keychains, login items, and launch agents. iCloud Drive is the
  // one part of `~/Library` that holds the owner's documents.
  "library",
];

/** Under a protected home path, but the owner's own documents. */
const UNPROTECTED_HOME_PATHS = ["library/mobile documents"];

/**
 * Directory names refused anywhere in the path: key stores, git internals
 * (hooks and config), and installed packages a program imports.
 */
const PROTECTED_SEGMENTS = new Set([
  ".ssh",
  ".gnupg",
  ".aws",
  ".git",
  "node_modules",
  "site-packages",
  "dist-packages",
  ".venv",
]);

/**
 * File names refused anywhere: env files, credential and token stores, key
 * material, and files a runtime loads on its own (Python's site hooks, Bun's
 * `preload`).
 */
const PROTECTED_FILE_NAME =
  /^(?:\.env(?:\..*)?|\.envrc|auth\.json|\.?credentials(?:\.[a-z0-9]+)*|secrets?\.[a-z0-9]+|.*tokens?\.json|.*\.(?:pem|key|p12|pfx)|(?:site|user)customize\.py|\.?bunfig\.toml)$/;

function isUnder(rel: string, prefix: string): boolean {
  return rel === prefix || rel.startsWith(`${prefix}/`);
}

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
  if (
    PROTECTED_HOME_PATHS.some((path) => isUnder(rel, path)) &&
    !UNPROTECTED_HOME_PATHS.some((path) => isUnder(rel, path))
  ) {
    return true;
  }
  const segments = rel.split("/");
  if (segments.some((segment) => PROTECTED_SEGMENTS.has(segment))) return true;
  return PROTECTED_FILE_NAME.test(segments[segments.length - 1] ?? "");
}

/**
 * Every root here is compared with a file's kernel realpath, so it takes the
 * same canonical form: a data directory configured in another case must still
 * contain its own files.
 */
const realpathOrNull = canonicalRealPath;

/**
 * A host file the editor may write once it is open: not executable (a script
 * on the PATH, a hook), and its only name. The editor saves by rename, so a
 * second name, which may be a protected file, would silently keep the old bytes.
 */
export function allowsHostFile(file: { mode: number; nlink: number }): boolean {
  return (file.mode & 0o111) === 0 && file.nlink === 1;
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
 * The sandbox workspace whose mount holds a symlink that resolving
 * `lexicalPath` follows, or null. The walk resolves the path the way the
 * kernel does, one component at a time, so `current` is always a physical
 * directory and each link's own location is known: a link in a sandbox mount
 * was planted by its guest, wherever it points. A path that cannot be walked
 * (missing, a loop) is null here; the realpath that served the read already
 * failed or decided it.
 */
async function sandboxLinkOnPath(
  lexicalPath: string,
  sources: FileEditOwnerSources,
): Promise<FileEditConfinement | null> {
  const sandboxes = sources.workspaces().flatMap((workspace) => {
    if (workspace.runtime !== "sandbox") return [];
    const root = workspaceMountRoot(workspace, { create: false });
    const realRoot = realpathOrNull(root);
    return realRoot ? [{ workspace, root, realRoot }] : [];
  });
  if (sandboxes.length === 0 || !isAbsolute(lexicalPath)) return null;

  const pending = lexicalPath.split("/").filter(Boolean);
  let current = "/";
  // The kernel's own limit on links followed while resolving one path.
  for (let links = 0; pending.length > 0;) {
    const name = pending.shift() as string;
    if (name === ".") continue;
    if (name === "..") {
      current = dirname(current);
      continue;
    }
    const next = join(current, name);
    try {
      if (!(await lstat(next)).isSymbolicLink()) {
        current = next;
        continue;
      }
      const holder = realpathOrNull(current);
      const sandbox = holder
        ? sandboxes.find((candidate) => isPathWithinRoot(holder, candidate.realRoot))
        : undefined;
      if (sandbox) return { workspace: sandbox.workspace, root: sandbox.root };
      if (++links > 32) return null;
      const target = await readlink(next);
      if (isAbsolute(target)) current = "/";
      pending.unshift(...target.split("/").filter(Boolean));
    } catch {
      return null;
    }
  }
  return null;
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

  // A host-context path through a link a sandbox guest planted is that
  // sandbox's, as if read in its context: the guest decides where the link
  // leads, so it never leads to an editable file outside the mount.
  const confinement = input.confinement ?? (await sandboxLinkOnPath(input.lexicalPath, sources));
  if (confinement) {
    // Sandbox context: the mount or nothing. A sandbox read already refused a
    // path outside it, so there this is the same boundary stated again.
    const realRoot = realpathOrNull(confinement.root);
    if (!realRoot || realPath === realRoot || !isPathWithinRoot(realPath, realRoot)) {
      return { kind: "refused", reason: "outside-home" };
    }
    return {
      kind: "owner",
      owner: {
        kind: "workspace",
        workspace: confinement.workspace,
        root: confinement.root,
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

  const skill = await sources.skillContaining(realPath);
  if (skill?.editable) {
    const { skillId, root, path } = skill;
    return { kind: "owner", owner: { kind: "skill", skillId, root, path } };
  }

  const workspace = await workspaceOwner(realPath, sources);
  if (workspace) return { kind: "owner", owner: workspace };

  // A package Skill is read-only through its Skill origin; the home does not
  // offer a second way in.
  if (skill) return { kind: "refused", reason: "protected" };

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
  if (sources.hostFilesEnabled?.() === false) return { kind: "refused", reason: "disabled" };
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
      return workspaceFileEditTarget(owner.workspace, owner.root, owner.path);
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

/**
 * A file in a workspace checkout (its mount or a worktree). The one kind of file it creates is a
 * pane layout, `.oppi/layouts/<name>.json` at the checkout's top, where Save Layout… puts a new
 * one; the folders are made with it. Every other workspace file only ever overwrites.
 */
export function workspaceFileEditTarget(
  workspace: Workspace,
  root: string,
  path: string,
): FileEditTarget {
  return {
    workspace,
    root,
    requestedPath: path,
    createsIn: (parentRelativeToRealRoot, fileName) =>
      parentRelativeToRealRoot === LAYOUTS_FOLDER && LAYOUT_FILE_NAME.test(fileName),
  };
}

/** Pi's agent directory: the allowlist again after symlinks, and where its files are created. */
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
 * containment, final-symlink, and canonical rechecks all run against it, and
 * every inspection also asks `allowsHostFile` of the opened file. Null for a
 * path outside the home, and for one with `.`, `..`, or repeated separators:
 * after a folder link the kernel's `..` is not the lexical one, so a
 * normalized name could be a different file from the one the owner judged.
 */
export function hostFileEditTarget(
  roots: ProtectedRoots,
  absolutePath: string,
): FileEditTarget | null {
  const resolved = resolve(absolutePath);
  if (resolved !== absolutePath) return null;
  if (resolved === roots.home || !isPathWithinRoot(resolved, roots.home)) return null;
  return {
    root: roots.home,
    requestedPath: toPosix(relative(roots.home, resolved)),
    allowsCanonical: (relativeToRealRoot) =>
      !isProtectedHostPath(join(roots.home, relativeToRealRoot), roots),
    allowsFile: allowsHostFile,
  };
}
