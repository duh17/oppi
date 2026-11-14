/**
 * Pane layout files on disk: `<checkout>/.oppi/layouts/<name>.json` in a workspace's root and in
 * each of its worktrees. There is no global folder.
 *
 * - Discovery: a folder is looked at again when a read finds its last look older than 2 s, and
 *   every folder looked at so far is swept every 60 s. No watcher. A change found either way
 *   sends `workspace_layouts_changed`.
 * - A folder is read only when `.oppi` and `layouts` are real directories. A file whose real path
 *   leaves the folder, a name outside `[a-z0-9][a-z0-9_-]{0,47}.json`, and every name after the
 *   first 64 are ignored. At most 16 KiB + 1 byte of a file is read.
 * - Cards: only a tracked `write` or `edit` (`tool-mutations.ts`) whose path is a layouts file
 *   makes a `layout_proposal`, live when the call ends and again for each trace page. A file a
 *   shell, script, person, or other program wrote is listed and never carded. Nothing is stored:
 *   the source "session" lasts while this process remembers the write and the file still holds
 *   what it left.
 *
 * Validation itself is `layout-validation.ts`, which touches no file system.
 */
import { createHash } from "node:crypto";
import { constants } from "node:fs";
import * as fs from "node:fs/promises";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";

import { execGit, gitTrustForWorkspace } from "./git-safe.js";
import {
  LAYOUT_FILE_NAME,
  LAYOUT_MAX_BYTES,
  LAYOUTS_FOLDER,
  layoutLeaves,
  validateLayoutBytes,
} from "./layout-validation.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import { canonicalRealPath, expandHome } from "./path-utils.js";
import { sessionWorkRoot } from "./session-work-root.js";
import type { Storage } from "./storage.js";
import { extractToolMutations, type ParsedToolMutation } from "./tool-mutations.js";
import type { TraceEvent } from "./trace.js";
import type {
  LayoutFileState,
  LayoutProposal,
  LayoutSource,
  Session,
  Workspace,
  WorkspaceLayoutResponse,
  WorkspaceLayoutSummary,
} from "./types.js";
import { resolveWorkspaceUserPath } from "./workspace-user-path.js";
import { listWorkspaceCheckouts, type WorkspaceCheckout } from "./workspace-checkouts.js";
import { MAIN_WORKTREE_ID } from "./worktrees.js";

const log = createLogger({ base: { component: "layout_files" } });

const MAX_FILES_PER_FOLDER = 64;
const LOOK_AGAIN_AFTER_MS = 2_000;
const SWEEP_INTERVAL_MS = 60_000;

/** A lexical layouts-file path in a tool call's arguments, before anything is resolved. */
const LAYOUTS_PATH = /(?:^|[/\\])\.oppi[/\\]layouts[/\\][^/\\]+$/;

type Checkout = WorkspaceCheckout;

interface FileSnapshot {
  name: string;
  realPath: string;
  /** Stat identity: a file is read again only when this changes. */
  statKey: string;
  state: Exclude<LayoutFileState, { state: "missing" }>;
}

interface FolderSnapshot {
  workspaceId: string;
  checkout: Checkout;
  lookedAt: number;
  files: Map<string, FileSnapshot>;
  /** Names tracked and unmodified in git, under this checkout's layouts folder. */
  inRepository: Set<string>;
  signature: string;
}

interface TrackedWrite {
  sessionId: string;
  hash: string;
}

/** A tracked tool call's layouts file, resolved to its checkout. */
interface LayoutTarget {
  workspace: Workspace;
  checkout: Checkout;
  name: string;
  mutations: ParsedToolMutation[];
}

/** Who hears that a workspace's layouts folder changed: the app event stream. */
export interface LayoutFileEvents {
  emitWorkspaceLayoutsChanged(workspaceId: string): void;
}

export class LayoutFiles {
  private readonly folders = new Map<string, FolderSnapshot>();
  private readonly pending = new Map<string, Promise<FolderSnapshot>>();
  private readonly checkouts = new Map<string, { at: number; list: Checkout[] }>();
  /** Real path → the newest tracked write that left it, while it still holds those bytes. */
  private readonly trackedWrites = new Map<string, TrackedWrite>();
  private sweepTimer: ReturnType<typeof setInterval> | undefined;

  constructor(
    private readonly storage: Pick<Storage, "getWorkspace" | "getDataDir">,
    private readonly events: LayoutFileEvents,
    private readonly now: () => number = Date.now,
  ) {}

  /** Every layout file in the workspace's checkouts: root first, then worktrees, each by name. */
  async list(workspace: Workspace): Promise<WorkspaceLayoutSummary[]> {
    const summaries: WorkspaceLayoutSummary[] = [];
    for (const checkout of await this.checkoutsOf(workspace)) {
      const folder = await this.folder(workspace, checkout, false);
      for (const file of folder.files.values()) {
        summaries.push(summaryOf(folder, file, this.sourceOf(folder, file)));
      }
    }
    return summaries;
  }

  /** One layout file, read now; null when the checkout or the file is not there. */
  async read(
    workspace: Workspace,
    name: string,
    worktreeId: string = MAIN_WORKTREE_ID,
  ): Promise<WorkspaceLayoutResponse | null> {
    const checkout = (await this.checkoutsOf(workspace)).find((c) => c.worktreeId === worktreeId);
    if (!checkout) return null;
    const folder = await this.folder(workspace, checkout, true);
    const file = folder.files.get(name);
    if (!file) return null;
    return {
      name,
      worktreeId: checkout.worktreeId,
      checkout: checkout.label,
      path: layoutPath(name),
      source: this.sourceOf(folder, file),
      file: file.state,
    };
  }

  /** Whether a tool call may touch a layouts file: a cheap lexical test, before any lookup. */
  static mayTouchLayouts(toolName: unknown, args: unknown): boolean {
    return extractToolMutations(toolName, args).some(
      (mutation) => mutation.path !== null && LAYOUTS_PATH.test(mutation.path),
    );
  }

  /**
   * The cards one tracked `write` or `edit` makes, read as the call ends. Records the session as
   * the file's writer and tells every client the folder changed.
   */
  async proposalsForToolCall(
    session: Session,
    toolCallId: string,
    toolName: unknown,
    args: unknown,
  ): Promise<LayoutProposal[]> {
    const targets = await this.targetsOf(session, toolName, args);
    const proposals: LayoutProposal[] = [];
    for (const target of targets) {
      // Looked at now, so the folder's change goes out with this call (`folder`).
      const folder = await this.folder(target.workspace, target.checkout, true);
      // A path that names the folder but is ignored there (a link out, past the first 64) is not
      // a layout file.
      const file = folder.files.get(target.name);
      if (!file) continue;
      const hash = "hash" in file.state ? file.state.hash : undefined;
      if (hash) this.trackedWrites.set(file.realPath, { sessionId: session.id, hash });
      proposals.push(await this.proposal(toolCallId, target, file));
    }
    return proposals;
  }

  /**
   * The cards a trace page holds: one per successful tracked write or edit of a layouts file,
   * each showing the file as it is now. Folding older cards for the same file is the client's.
   */
  async proposalsForTrace(
    session: Session,
    trace: readonly TraceEvent[],
  ): Promise<LayoutProposal[]> {
    if (!session.workspaceId) return [];
    const succeeded = new Set<string>();
    for (const event of trace) {
      if (event.type === "toolResult" && event.toolCallId && event.isError !== true) {
        succeeded.add(event.toolCallId);
      }
    }
    const proposals: LayoutProposal[] = [];
    for (const event of trace) {
      if (event.type !== "toolCall" || !succeeded.has(event.id)) continue;
      if (!LayoutFiles.mayTouchLayouts(event.tool, event.args)) continue;
      for (const target of await this.targetsOf(session, event.tool, event.args)) {
        const folder = await this.folder(target.workspace, target.checkout, false);
        const file = folder.files.get(target.name);
        proposals.push(
          file
            ? await this.proposal(event.id, target, file)
            : {
                ...proposalBase(event.id, target),
                file: { state: "missing" },
              },
        );
      }
    }
    return proposals;
  }

  private async proposal(
    toolCallId: string,
    target: LayoutTarget,
    file: FileSnapshot,
  ): Promise<LayoutProposal> {
    const left = await leftByCall(target.mutations, file);
    return {
      ...proposalBase(toolCallId, target),
      file: file.state,
      ...(left ? {} : { changed: true as const }),
    };
  }

  private sourceOf(folder: FolderSnapshot, file: FileSnapshot): LayoutSource {
    const hash = "hash" in file.state ? file.state.hash : undefined;
    const tracked = this.trackedWrites.get(file.realPath);
    if (tracked && hash && tracked.hash === hash) {
      return { kind: "session", sessionId: tracked.sessionId };
    }
    if (folder.inRepository.has(file.name)) return { kind: "repository" };
    return { kind: "folder" };
  }

  /** The layouts files a tracked tool call's paths name, in the session's own workspace. */
  private async targetsOf(
    session: Session,
    toolName: unknown,
    args: unknown,
  ): Promise<LayoutTarget[]> {
    const workspace = session.workspaceId
      ? this.storage.getWorkspace(session.workspaceId)
      : undefined;
    if (!workspace) return [];
    const mutations = extractToolMutations(toolName, args).filter(
      (mutation) => mutation.path !== null && LAYOUTS_PATH.test(mutation.path),
    );
    if (mutations.length === 0) return [];
    const work = await sessionWorkRoot(session, this.storage, { create: false });
    if (work.kind !== "ok") return [];

    const checkouts = await this.checkoutsOf(workspace);
    const byKey = new Map<string, LayoutTarget>();
    for (const mutation of mutations) {
      const absolute = hostPathOf(workspace, work.root, mutation.path as string);
      if (!absolute) continue;
      const name = basename(absolute);
      if (!LAYOUT_FILE_NAME.test(name)) continue;
      const realCheckout = canonicalRealPath(dirname(dirname(dirname(absolute))));
      const checkout = checkouts.find((c) => canonicalRealPath(c.root) === realCheckout);
      if (!realCheckout || !checkout) continue;
      const key = `${checkout.worktreeId}\0${name}`;
      const existing = byKey.get(key);
      if (existing) existing.mutations.push(mutation);
      else {
        byKey.set(key, {
          workspace,
          checkout,
          name: name.slice(0, -".json".length),
          mutations: [mutation],
        });
      }
    }
    return [...byKey.values()];
  }

  /** The workspace root, then its worktrees. A sandbox has only its mount. */
  private async checkoutsOf(workspace: Workspace): Promise<Checkout[]> {
    const now = this.now();
    const cached = this.checkouts.get(workspace.id);
    if (cached && now - cached.at < LOOK_AGAIN_AFTER_MS) return cached.list;
    const list = await listWorkspaceCheckouts(workspace, this.storage.getDataDir(), "layout_files");
    this.checkouts.set(workspace.id, { at: now, list });
    return list;
  }

  /**
   * A checkout's folder, looked at again when the last look is older than 2 s (or `fresh`). A
   * look that finds other files than the last one (none counts) tells every client.
   */
  private async folder(
    workspace: Workspace,
    checkout: Checkout,
    fresh: boolean,
  ): Promise<FolderSnapshot> {
    const key = `${workspace.id}\0${checkout.root}`;
    const cached = this.folders.get(key);
    if (cached && !fresh && this.now() - cached.lookedAt < LOOK_AGAIN_AFTER_MS) return cached;
    const running = this.pending.get(key);
    if (running && !fresh) return running;
    const look = this.look(workspace, checkout, cached).finally(() => {
      if (this.pending.get(key) === look) this.pending.delete(key);
    });
    this.pending.set(key, look);
    const folder = await look;
    this.folders.set(key, folder);
    if ((cached?.signature ?? "") !== folder.signature) {
      this.events.emitWorkspaceLayoutsChanged(workspace.id);
    }
    // The 60 s sweep of every folder looked at so far starts with the first look; it never
    // keeps the process alive.
    this.sweepTimer ??= setInterval(() => void this.sweep(), SWEEP_INTERVAL_MS);
    this.sweepTimer.unref?.();
    return folder;
  }

  private async look(
    workspace: Workspace,
    checkout: Checkout,
    previous: FolderSnapshot | undefined,
  ): Promise<FolderSnapshot> {
    const empty: FolderSnapshot = {
      workspaceId: workspace.id,
      checkout,
      lookedAt: this.now(),
      files: new Map(),
      inRepository: new Set(),
      signature: "",
    };
    // A missing folder means no layouts; nothing creates it but a save.
    const realFolder = await realLayoutsFolder(checkout.root);
    if (!realFolder) return empty;
    let names: string[];
    try {
      names = (await fs.readdir(realFolder)).filter((name) => LAYOUT_FILE_NAME.test(name));
    } catch {
      return empty;
    }
    names.sort();

    const files = new Map<string, FileSnapshot>();
    for (const fileName of names.slice(0, MAX_FILES_PER_FOLDER)) {
      const name = fileName.slice(0, -".json".length);
      const snapshot = await readLayoutFile(realFolder, fileName, previous?.files.get(name));
      if (snapshot) files.set(name, { ...snapshot, name });
    }
    const signature = [...files.values()].map((file) => `${file.name}:${file.statKey}`).join("\n");
    return {
      ...empty,
      files,
      inRepository:
        files.size > 0
          ? await cleanInRepository(workspace, checkout.root, [...files.keys()])
          : new Set<string>(),
      signature,
    };
  }

  private async sweep(): Promise<void> {
    for (const folder of [...this.folders.values()]) {
      const workspace = this.storage.getWorkspace(folder.workspaceId);
      if (!workspace) {
        this.folders.delete(`${folder.workspaceId}\0${folder.checkout.root}`);
        continue;
      }
      try {
        await this.folder(workspace, folder.checkout, true);
      } catch (error: unknown) {
        log.warn("layout_files.sweep_failed", {
          workspaceId: folder.workspaceId,
          error: safeErrorMessage(error),
        });
      }
    }
  }
}

function layoutPath(name: string): string {
  return `${LAYOUTS_FOLDER}/${name}.json`;
}

function proposalBase(toolCallId: string, target: LayoutTarget): Omit<LayoutProposal, "file"> {
  return {
    toolCallId,
    workspaceId: target.workspace.id,
    worktreeId: target.checkout.worktreeId,
    checkout: target.checkout.label,
    name: target.name,
    path: layoutPath(target.name),
  };
}

function summaryOf(
  folder: FolderSnapshot,
  file: FileSnapshot,
  source: LayoutSource,
): WorkspaceLayoutSummary {
  const state = file.state;
  const base = {
    name: file.name,
    worktreeId: folder.checkout.worktreeId,
    checkout: folder.checkout.label,
    path: layoutPath(file.name),
    ...(state.hash ? { hash: state.hash } : {}),
    source,
  };
  switch (state.state) {
    case "valid":
      return {
        ...base,
        title: state.layout.title,
        leafCount: layoutLeaves(state.layout.root).length,
      };
    case "newer":
      return { ...base, ...(state.title ? { title: state.title } : {}), newerVersion: state.v };
    case "invalid":
      return { ...base, ...(state.problems[0] ? { problem: state.problems[0] } : {}) };
  }
}

/**
 * The host path a tool call's path names: relative to the session's checkout, absolute, `~/`, or
 * (in a sandbox) the guest path of its mount.
 */
function hostPathOf(workspace: Workspace, sessionRoot: string, path: string): string | null {
  if (workspace.runtime === "sandbox") {
    return resolveWorkspaceUserPath({ workspace, requestedPath: path, root: sessionRoot });
  }
  const expanded = expandHome(path);
  return isAbsolute(expanded) ? resolve(expanded) : resolve(sessionRoot, expanded);
}

/** `<root>/.oppi/layouts` when both parts are real directories, as its real path. */
async function realLayoutsFolder(root: string): Promise<string | null> {
  const realRoot = canonicalRealPath(root);
  if (!realRoot) return null;
  const oppi = join(realRoot, ".oppi");
  const layouts = join(oppi, "layouts");
  try {
    for (const directory of [oppi, layouts]) {
      const stat = await fs.lstat(directory);
      if (stat.isSymbolicLink() || !stat.isDirectory()) return null;
    }
  } catch {
    return null;
  }
  return layouts;
}

/**
 * One file of a real layouts folder: followed only when its real path stays in the folder, read
 * through `O_NOFOLLOW` up to one byte past the limit, and parsed again only when its stat changed.
 */
async function readLayoutFile(
  realFolder: string,
  fileName: string,
  previous: FileSnapshot | undefined,
): Promise<Omit<FileSnapshot, "name"> | null> {
  const lexical = join(realFolder, fileName);
  let realPath: string;
  try {
    realPath = await fs.realpath(lexical);
  } catch {
    return null;
  }
  if (dirname(realPath) !== realFolder) return null;

  let handle: fs.FileHandle;
  try {
    handle = await fs.open(
      realPath,
      constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
    );
  } catch {
    return null;
  }
  try {
    const stat = await handle.stat();
    if (!stat.isFile()) return null;
    const statKey = `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeMs}:${stat.ctimeMs}`;
    if (previous && previous.realPath === realPath && previous.statKey === statKey) {
      return { realPath, statKey, state: previous.state };
    }
    const buffer = Buffer.alloc(LAYOUT_MAX_BYTES + 1);
    let length = 0;
    while (length < buffer.length) {
      const { bytesRead } = await handle.read(buffer, length, buffer.length - length, length);
      if (bytesRead === 0) break;
      length += bytesRead;
    }
    const bytes = buffer.subarray(0, length);
    return { realPath, statKey, state: layoutFileState(bytes) };
  } catch {
    return null;
  } finally {
    await handle.close().catch(() => {});
  }
}

/** What the validator says about a file's bytes, with the bytes' hash when it read them all. */
function layoutFileState(bytes: Uint8Array): Exclude<LayoutFileState, { state: "missing" }> {
  const result = validateLayoutBytes(bytes);
  const hash = bytes.length > LAYOUT_MAX_BYTES ? undefined : layoutHash(bytes);
  switch (result.kind) {
    case "valid":
      return {
        state: "valid",
        hash: hash as string,
        layout: result.layout,
        warnings: result.warnings,
      };
    case "newer":
      return {
        state: "newer",
        hash: hash as string,
        v: result.v,
        ...(result.title ? { title: result.title } : {}),
      };
    case "invalid":
      return {
        state: "invalid",
        ...(hash ? { hash } : {}),
        problems: result.problems,
        warnings: result.warnings,
      };
  }
}

/** The editor's ETag body for the same bytes: `sha256-<hex>`. */
function layoutHash(bytes: Uint8Array): string {
  return `sha256-${createHash("sha256").update(bytes).digest("hex")}`;
}

/**
 * The layouts in `names` that git tracks unmodified. `git status` with every untracked and
 * ignored file listed one by one names every other file in the folder, so a file it leaves out is
 * tracked and clean. Outside a repository nothing is.
 */
async function cleanInRepository(
  workspace: Workspace,
  root: string,
  names: readonly string[],
): Promise<Set<string>> {
  const result = await execGit(
    gitTrustForWorkspace(workspace),
    root,
    [
      "status",
      "--porcelain=v1",
      "-z",
      "--untracked-files=all",
      "--ignored=traditional",
      "--",
      LAYOUTS_FOLDER,
    ],
    { timeout: 5_000 },
  );
  if (result.error) return new Set();
  const listed = new Set<string>();
  const records = String(result.stdout).split("\0");
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index] ?? "";
    if (record.length < 4) continue;
    listed.add(basename(record.slice(3)));
    // A rename or copy is followed by its source path.
    if (record[0] === "R" || record[0] === "C") index += 1;
  }
  return new Set(names.filter((name) => !listed.has(`${name}.json`)));
}

/**
 * Whether the file still holds what a tool call left: a `write`'s exact content, or every
 * replacement text of its edits.
 */
async function leftByCall(mutations: ParsedToolMutation[], file: FileSnapshot): Promise<boolean> {
  if (!("hash" in file.state) || !file.state.hash) return false;
  const last = mutations[mutations.length - 1];
  if (last?.kind === "write") {
    return layoutHash(new TextEncoder().encode(last.content)) === file.state.hash;
  }
  let text: string;
  try {
    text = await fs.readFile(file.realPath, "utf8");
  } catch {
    return false;
  }
  return mutations.every(
    (mutation) => mutation.kind !== "edit" || !mutation.newText || text.includes(mutation.newText),
  );
}
