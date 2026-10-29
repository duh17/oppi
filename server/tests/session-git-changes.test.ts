import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { SessionEventProcessor, type EventProcessorSessionState } from "../src/session-events.js";
import { buildSessionSummary } from "../src/session-summary.js";
import { SessionTraceService } from "../src/session-trace-service.js";
import { ToolOutputSnapshots } from "../src/tool-output-sidecar.js";
import type { ServerMessage, Session, Workspace } from "../src/types.js";
import { managedWorktreesRoot } from "../src/worktrees.js";

// Every git process the server starts goes through git-safe's `execFile("git", ...)`.
const spawned = vi.hoisted(() => ({ calls: [] as string[][] }));
vi.mock("node:child_process", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return {
    ...actual,
    execFile: ((file: string, args: string[], ...rest: unknown[]) => {
      if (file === "git") spawned.calls.push(args);
      return (actual.execFile as (...all: unknown[]) => unknown)(file, args, ...rest);
    }) as typeof actual.execFile,
  };
});

const roots: string[] = [];
let repoCount = 0;
/** The workspace id of the latest `makeRepo`, the default for `makeSession`. */
let workspaceId = "";
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

/** A repo with one commit and an Oppi-managed worktree on `feature`. */
function makeRepo(): { workspace: Workspace; dataDir: string; worktreePath: string } {
  const root = mkdtempSync(join(tmpdir(), "oppi-session-git-changes-"));
  roots.push(root);
  const repo = join(root, "repo");
  const dataDir = join(root, "data");
  mkdirSync(repo);
  git(repo, "init", "-q", "-b", "main");
  git(repo, "config", "user.email", "test@example.com");
  git(repo, "config", "user.name", "Test");
  writeFileSync(join(repo, "a.txt"), "one\ntwo\nthree\n");
  writeFileSync(join(repo, "b.txt"), "keep\n");
  git(repo, "add", ".");
  git(repo, "commit", "-q", "-m", "base");
  // A fresh workspace id per repo: the module remembers a removed worktree as gone
  // for a while, and an earlier test's removed worktree must not shadow this one.
  workspaceId = `ws-git-${++repoCount}`;
  const workspace = { id: workspaceId, name: "Repo", hostMount: repo } as Workspace;
  const worktreePath = join(managedWorktreesRoot(dataDir, workspace.id), "feature");
  mkdirSync(join(worktreePath, ".."), { recursive: true });
  git(repo, "worktree", "add", "-q", "-b", "feature", worktreePath);
  return { workspace, dataDir, worktreePath };
}

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "sess-git",
    workspaceId,
    worktreeId: "feature",
    status: "busy",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeActive(session: Session): EventProcessorSessionState {
  return {
    session,
    pendingUIRequests: new Map(),
    toolOutputSnapshots: new ToolOutputSnapshots(),
    streamedAssistantText: "",
    toolNames: new Map(),
    streamingToolUpdatesSeen: new Map(),
  };
}

function makeProcessor(workspace: Workspace, dataDir: string) {
  const messages: ServerMessage[] = [];
  const waiters: Array<{ type: string; resolve: () => void }> = [];
  const processor = new SessionEventProcessor({
    storage: { getWorkspace: () => workspace, getDataDir: () => dataDir } as never,
    mobileRenderers: new MobileRendererRegistry(),
    broadcast: (_key, message) => {
      messages.push(message);
      for (const waiter of waiters.splice(0)) {
        if (waiter.type === message.type) waiter.resolve();
        else waiters.push(waiter);
      }
    },
    persistSessionNow: vi.fn(),
    markSessionDirty: vi.fn(),
  });
  const next = (type: ServerMessage["type"]): Promise<void> =>
    new Promise((resolve) => waiters.push({ type, resolve }));
  return { processor, messages, next };
}

function toolCall(
  processor: SessionEventProcessor,
  active: EventProcessorSessionState,
  index: number,
  toolName: string,
  args: Record<string, unknown>,
): void {
  const toolCallId = `tool-${index}`;
  processor.updateSessionFromEvent("sess-git", active, {
    type: "tool_execution_start",
    toolName,
    toolCallId,
    args,
  } as never);
  processor.updateSessionFromEvent("sess-git", active, {
    type: "tool_execution_end",
    toolName,
    toolCallId,
    result: { content: [] },
    isError: false,
  } as never);
}

function makeTraceService(workspace: Workspace, dataDir: string): SessionTraceService {
  return new SessionTraceService({
    mobileRenderers: new MobileRendererRegistry(),
    storage: {
      getDataDir: () => dataDir,
      getSession: () => undefined,
      getWorkspace: () => workspace,
    },
    sessionRuntimes: {
      refreshSessionState: async () => null,
      getToolFullOutputPath: () => null,
      getToolPartialOutput: () => null,
    } as never,
    ensureSessionContextWindow: (session) => session,
  });
}

describe("worktree session git changes", () => {
  it("runs no git per tool call and a bounded read per settled turn", async () => {
    const { workspace, dataDir, worktreePath } = makeRepo();
    const { processor, next } = makeProcessor(workspace, dataDir);
    const session = makeSession();
    const active = makeActive(session);
    spawned.calls.length = 0;

    // A turn: edits through tools, plus a file only bash created and a commit.
    processor.updateSessionFromEvent("sess-git", active, { type: "agent_start" } as never);
    writeFileSync(join(worktreePath, "a.txt"), "one\nTWO\nthree\nfour\n");
    toolCall(processor, active, 1, "edit", { path: "a.txt", oldText: "two", newText: "TWO" });
    toolCall(processor, active, 2, "write", { path: "agent://child-1", content: "not a file" });
    writeFileSync(join(worktreePath, "bash-made.txt"), "x\ny\n");
    toolCall(processor, active, 3, "bash", { command: "printf 'x\\ny\\n' > bash-made.txt" });
    git(worktreePath, "add", "a.txt");
    git(worktreePath, "commit", "-q", "-m", "feature edit");
    toolCall(processor, active, 4, "bash", { command: "git commit" });
    expect(spawned.calls).toEqual([]);

    // The pre-existing debounced status refresh is the only git the tool calls cause.
    await next("git_status");
    const toolPhase = spawned.calls.length;
    spawned.calls.length = 0;

    processor.updateSessionFromEvent("sess-git", active, { type: "agent_end" } as never);
    expect(spawned.calls).toEqual([]);
    const summarySent = next("session_summary");
    processor.updateSessionFromEvent("sess-git", active, { type: "agent_settled" } as never);
    await summarySent;
    const firstSettle = spawned.calls.map((args) => args[0]);
    // Cold: worktree path (rev-parse --show-toplevel, worktree list), then the read.
    expect(firstSettle.sort()).toEqual(
      ["diff-index", "ls-files", "merge-base", "rev-parse", "rev-parse", "worktree"].sort(),
    );

    expect(session.changeStats?.worktree).toMatchObject({
      filesChanged: 2,
      changedFiles: ["a.txt", "bash-made.txt"],
      // a.txt +2 -1, bash-made.txt +2.
      addedLines: 4,
      removedLines: 1,
    });
    // The session's own touched list keeps tool paths only, never harness URLs.
    expect(session.changeStats?.changedFiles).toEqual(["a.txt"]);

    // A second turn reuses the worktree path and merge-base (HEAD unchanged).
    spawned.calls.length = 0;
    toolCall(processor, active, 5, "bash", { command: "true" });
    const secondSummary = next("session_summary");
    processor.updateSessionFromEvent("sess-git", active, { type: "agent_settled" } as never);
    await secondSummary;
    const secondSettle = spawned.calls.map((args) => args[0]);
    expect(secondSettle.sort()).toEqual(["diff-index", "ls-files", "rev-parse"]);
    expect(toolPhase).toBeGreaterThan(0);

    // A turn with no tool reads nothing.
    spawned.calls.length = 0;
    processor.updateSessionFromEvent("sess-git", active, { type: "agent_settled" } as never);
    await new Promise((resolve) => setImmediate(resolve));
    expect(spawned.calls).toEqual([]);
  }, 15_000);

  it("never writes the worktree's index, and ignores files whose stat changed but content did not", async () => {
    const { workspace, dataDir, worktreePath } = makeRepo();
    const { processor, next } = makeProcessor(workspace, dataDir);
    const session = makeSession({ id: "sess-index" });
    const active = makeActive(session);
    const index = join(git(worktreePath, "rev-parse", "--absolute-git-dir"), "index");
    const before = statSync(index).mtimeMs;
    // Newer mtime, same bytes: porcelain diff/status would refresh and rewrite the index.
    utimesSync(join(worktreePath, "b.txt"), new Date(), new Date(Date.now() + 5_000));
    writeFileSync(join(worktreePath, "a.txt"), "one\ntwo\nthree\nfour\n");

    toolCall(processor, active, 1, "bash", { command: "touch b.txt" });
    const summarySent = next("session_summary");
    processor.updateSessionFromEvent("sess-index", active, { type: "agent_settled" } as never);
    await summarySent;

    expect(statSync(index).mtimeMs).toBe(before);
    expect(session.changeStats?.worktree).toMatchObject({
      filesChanged: 1,
      changedFiles: ["a.txt"],
    });
  });

  it("serves the turn-end snapshot without git, then fresh after the agent acts", async () => {
    const { workspace, dataDir, worktreePath } = makeRepo();
    const { processor, next } = makeProcessor(workspace, dataDir);
    const session = makeSession({
      changeStats: {
        mutatingToolCalls: 1,
        filesChanged: 1,
        changedFiles: [join(worktreePath, "a.txt")],
      },
    });
    const active = makeActive(session);
    writeFileSync(join(worktreePath, "a.txt"), "one\ntwo\nthree\nfour\n");
    writeFileSync(join(worktreePath, "new.txt"), "n\n");
    toolCall(processor, active, 0, "bash", { command: "echo n > new.txt" });
    const summarySent = next("session_summary");
    processor.updateSessionFromEvent("sess-git", active, { type: "agent_settled" } as never);
    await summarySent;

    const service = makeTraceService(workspace, dataDir);
    spawned.calls.length = 0;
    const cached = await service.getSessionWorktreeChanges(session);
    expect(spawned.calls).toEqual([]);
    expect(cached).toMatchObject({
      kind: "ok",
      changes: {
        live: true,
        changedFileCount: 2,
        addedLines: 2,
        removedLines: 0,
        files: [
          { path: "a.txt", status: "M", addedLines: 1, removedLines: 0, sessionTouched: true },
          { path: "new.txt", status: "??", addedLines: 1, removedLines: 0, sessionTouched: false },
        ],
      },
    });
    // The summary the session list receives carries the counts; the paths stay on the session.
    const summarized = buildSessionSummary(session).changeStats?.worktree;
    expect(summarized).toMatchObject({ filesChanged: 2, addedLines: 2, removedLines: 0 });
    expect(summarized?.changedFiles).toBeUndefined();
    expect(session.changeStats?.worktree?.changedFiles).toEqual(["a.txt", "new.txt"]);

    // The session's own touched list stays reachable, with no git.
    expect(service.listSessionChanges(session).files).toEqual([
      { path: join(worktreePath, "a.txt") },
    ]);
    expect(spawned.calls).toEqual([]);

    // Any tool end invalidates the snapshot: a bash-made file shows up on the next read.
    writeFileSync(join(worktreePath, "later.txt"), "l\n");
    toolCall(processor, active, 1, "bash", { command: "touch later.txt" });
    const fresh = await service.getSessionWorktreeChanges(session);
    expect(fresh.kind === "ok" && fresh.changes.files.map((file) => file.path)).toEqual([
      "a.txt",
      "later.txt",
      "new.txt",
    ]);
    expect(spawned.calls.map((args) => args[0]).sort()).toEqual([
      "diff-index",
      "ls-files",
      "rev-parse",
    ]);
  });

  it("diffs a file against the worktree base, committed and uncommitted changes together", async () => {
    const { workspace, dataDir, worktreePath } = makeRepo();
    writeFileSync(join(worktreePath, "a.txt"), "one\nTWO\nthree\n");
    git(worktreePath, "commit", "-q", "-am", "commit in worktree");
    writeFileSync(join(worktreePath, "a.txt"), "one\nTWO\nthree\nfour\n");
    writeFileSync(join(worktreePath, "added.txt"), "fresh\n");
    // The main checkout moving on does not move the base.
    writeFileSync(join(workspace.hostMount, "b.txt"), "main moved\n");
    git(workspace.hostMount, "commit", "-q", "-am", "main moves");

    const service = makeTraceService(workspace, dataDir);
    const session = makeSession({ id: "sess-diff" });
    const listed = await service.getSessionWorktreeChanges(session);
    expect(listed.kind === "ok" && listed.changes.files.map((f) => f.path)).toEqual([
      "a.txt",
      "added.txt",
    ]);

    const modified = await service.getSessionWorktreeDiff({ session, path: "a.txt" });
    expect(modified).toMatchObject({
      kind: "ok",
      diff: {
        baselineText: "one\ntwo\nthree\n",
        currentText: "one\nTWO\nthree\nfour\n",
        addedLines: 2,
        removedLines: 1,
      },
    });
    const added = await service.getSessionWorktreeDiff({ session, path: "added.txt" });
    expect(added).toMatchObject({ kind: "ok", diff: { baselineText: "", addedLines: 1 } });
    expect(
      (await service.getSessionWorktreeDiff({ session, path: "../repo/a.txt" })).kind,
    ).not.toBe("ok");
  });

  it("falls back to the stored list and stored commits once the worktree is removed", async () => {
    const { workspace, dataDir, worktreePath } = makeRepo();
    const { processor, next } = makeProcessor(workspace, dataDir);
    const session = makeSession({ id: "sess-landed" });
    const active = makeActive(session);
    writeFileSync(join(worktreePath, "a.txt"), "one\ntwo\nthree\nfour\n");
    git(worktreePath, "commit", "-q", "-am", "landed work");
    toolCall(processor, active, 1, "bash", { command: "git commit -am 'landed work'" });
    const summarySent = next("session_summary");
    processor.updateSessionFromEvent("sess-landed", active, { type: "agent_settled" } as never);
    await summarySent;
    const stored = session.changeStats?.worktree;
    expect(stored?.filesChanged).toBe(1);

    // Landing fast-forwards main to the worktree: HEAD becomes the merge-base. The
    // next turn end keeps measuring from the stored base instead of reading zero.
    git(workspace.hostMount, "merge", "-q", "--ff-only", "feature");
    toolCall(processor, active, 2, "bash", { command: "git log" });
    const landedSummary = next("session_summary");
    processor.updateSessionFromEvent("sess-landed", active, { type: "agent_settled" } as never);
    await landedSummary;
    expect(session.changeStats?.worktree).toMatchObject({
      filesChanged: 1,
      addedLines: 1,
      baseSha: stored?.baseSha,
    });

    git(workspace.hostMount, "worktree", "remove", worktreePath);

    // A later settle cannot read the worktree and keeps the stored value. The
    // list request shares the settle's read, so it resolves after the settle's.
    const before = structuredClone(session.changeStats?.worktree);
    toolCall(processor, active, 3, "bash", { command: "true" });
    processor.updateSessionFromEvent("sess-landed", active, { type: "agent_settled" } as never);
    const service = makeTraceService(workspace, dataDir);
    const listed = await service.getSessionWorktreeChanges(session);
    expect(session.changeStats?.worktree).toEqual(before);
    expect(listed).toMatchObject({
      kind: "ok",
      changes: {
        live: false,
        changedFileCount: 1,
        addedLines: 1,
        files: [{ path: "a.txt", sessionTouched: false }],
      },
    });

    // A main-checkout session has no worktree view; its touched list is the answer.
    const mainSession = makeSession({ id: "sess-main", worktreeId: "main" });
    expect((await service.getSessionWorktreeChanges(mainSession)).kind).toBe(
      "not-worktree-session",
    );
    expect(
      (await service.getSessionWorktreeDiff({ session: mainSession, path: "a.txt" })).kind,
    ).toBe("not-worktree-session");

    const diff = await service.getSessionWorktreeDiff({ session, path: "a.txt" });
    expect(diff).toMatchObject({
      kind: "ok",
      diff: {
        baselineText: "one\ntwo\nthree\n",
        currentText: "one\ntwo\nthree\nfour\n",
        addedLines: 1,
      },
    });
  });

  /** One turn: a tool runs, the run settles, and the turn-end read lands. */
  async function settleTurn(
    processor: SessionEventProcessor,
    active: EventProcessorSessionState,
    next: (type: ServerMessage["type"]) => Promise<void>,
    tool: number,
  ): Promise<void> {
    const summary = next("session_summary");
    toolCall(processor, active, tool, "bash", { command: "git status" });
    processor.updateSessionFromEvent(active.session.id, active, { type: "agent_settled" } as never);
    await summary;
  }

  function commitOnMain(repo: string, file: string): void {
    writeFileSync(join(repo, file), "someone else's work\n");
    git(repo, "add", file);
    git(repo, "commit", "-q", "-m", `main adds ${file}`);
  }

  it("a worktree with no commits of its own that syncs with main shows only its own changes", async () => {
    const { workspace, dataDir, worktreePath } = makeRepo();
    const { processor, next } = makeProcessor(workspace, dataDir);
    const session = makeSession({ id: "sess-sync" });
    const active = makeActive(session);
    writeFileSync(join(worktreePath, "a.txt"), "one\ntwo\nthree\nfour\n");
    await settleTurn(processor, active, next, 1);
    expect(session.changeStats?.worktree).toMatchObject({
      filesChanged: 1,
      changedFiles: ["a.txt"],
    });

    // Main moves on; the worktree fast-forwards onto it (HEAD becomes the merge-base).
    commitOnMain(workspace.hostMount, "main-only.txt");
    git(worktreePath, "merge", "-q", "--ff-only", "main");
    await settleTurn(processor, active, next, 2);

    expect(session.changeStats?.worktree).toMatchObject({
      filesChanged: 1,
      changedFiles: ["a.txt"],
    });
  });

  it("after a landing, a sync with main never adds main's commits and keeps the landed count", async () => {
    const { workspace, dataDir, worktreePath } = makeRepo();
    const { processor, next } = makeProcessor(workspace, dataDir);
    const session = makeSession({ id: "sess-land-sync" });
    const active = makeActive(session);
    writeFileSync(join(worktreePath, "a.txt"), "one\ntwo\nthree\nfour\n");
    git(worktreePath, "commit", "-q", "-am", "own work");
    await settleTurn(processor, active, next, 1);

    // Landed, then main gets someone else's commit and the worktree syncs onto it.
    git(workspace.hostMount, "merge", "-q", "--ff-only", "feature");
    commitOnMain(workspace.hostMount, "main-only.txt");
    git(worktreePath, "merge", "-q", "--ff-only", "main");
    toolCall(processor, active, 2, "bash", { command: "git merge main" });
    // The read is empty and landed, so nothing is broadcast: the list request
    // shares the settle's read and resolves after the settle's handling of it.
    processor.updateSessionFromEvent("sess-land-sync", active, { type: "agent_settled" } as never);
    const listed = await makeTraceService(workspace, dataDir).getSessionWorktreeChanges(session);

    expect(session.changeStats?.worktree).toMatchObject({
      filesChanged: 1,
      changedFiles: ["a.txt"],
    });
    // The list agrees with the kept count: the landed files, not main's.
    expect(listed).toMatchObject({
      kind: "ok",
      changes: { live: false, changedFileCount: 1, files: [{ path: "a.txt" }] },
    });
  });

  /** The worktree's own work: an edit and a new file in one commit. */
  function commitOwnWork(worktreePath: string): void {
    writeFileSync(join(worktreePath, "a.txt"), "one\ntwo\nthree\nfour\n");
    writeFileSync(join(worktreePath, "new.txt"), "new\n");
    git(worktreePath, "add", ".");
    git(worktreePath, "commit", "-q", "-m", "own work");
  }

  const ffOnlyLanding = (repo: string): void => {
    git(repo, "merge", "-q", "--ff-only", "feature");
  };

  it.each([
    {
      label: "plain commits, ff-only landing, on the first turn",
      earlierTurn: false,
      prepare: (_repo: string, worktreePath: string) => commitOwnWork(worktreePath),
      land: ffOnlyLanding,
      files: ["a.txt", "new.txt"],
    },
    {
      label: "plain commits after a turn that stored only uncommitted work",
      earlierTurn: true,
      prepare: (_repo: string, worktreePath: string) => commitOwnWork(worktreePath),
      land: ffOnlyLanding,
      files: ["a.txt", "new.txt"],
    },
    {
      label: "a fixup autosquashed while rebasing onto a moved main",
      earlierTurn: false,
      prepare: (repo: string, worktreePath: string) => {
        writeFileSync(join(worktreePath, "a.txt"), "one\ntwo\nthree\nfour\n");
        git(worktreePath, "commit", "-q", "-am", "own work");
        writeFileSync(join(worktreePath, "new.txt"), "new\n");
        git(worktreePath, "add", "new.txt");
        git(worktreePath, "commit", "-q", "-m", "fixup! own work");
        commitOnMain(repo, "main-only.txt");
        execFileSync("git", ["rebase", "-q", "-i", "--autosquash", "main"], {
          cwd: worktreePath,
          env: { ...process.env, GIT_SEQUENCE_EDITOR: ":" },
        });
      },
      land: ffOnlyLanding,
      files: ["a.txt", "new.txt"],
    },
    {
      label: "a conflicting merge of main resolved in the worktree",
      earlierTurn: false,
      prepare: (repo: string, worktreePath: string) => {
        writeFileSync(join(worktreePath, "a.txt"), "one\nOURS\nthree\n");
        git(worktreePath, "commit", "-q", "-am", "own work");
        writeFileSync(join(repo, "a.txt"), "one\nTHEIRS\nthree\n");
        git(repo, "commit", "-q", "-am", "main edits a.txt");
        commitOnMain(repo, "main-only.txt");
        try {
          git(worktreePath, "merge", "-q", "main");
        } catch {
          // The conflict is the point; it is resolved below.
        }
        writeFileSync(join(worktreePath, "a.txt"), "one\nOURS\nTHEIRS\nthree\n");
        git(worktreePath, "add", "a.txt");
        git(worktreePath, "commit", "-q", "--no-edit");
      },
      land: ffOnlyLanding,
      files: ["a.txt"],
    },
    {
      label: "own work replayed by git pull --rebase onto a moved main",
      earlierTurn: false,
      prepare: (repo: string, worktreePath: string) => {
        commitOwnWork(worktreePath);
        commitOnMain(repo, "main-only.txt");
        git(worktreePath, "pull", "-q", "--rebase", ".", "main");
      },
      land: ffOnlyLanding,
      files: ["a.txt", "new.txt"],
    },
    {
      label: "a merge commit made by git pull of a moved main",
      earlierTurn: false,
      prepare: (repo: string, worktreePath: string) => {
        commitOwnWork(worktreePath);
        commitOnMain(repo, "main-only.txt");
        git(worktreePath, "pull", "-q", "--no-rebase", "--no-ff", "--no-edit", ".", "main");
      },
      land: ffOnlyLanding,
      files: ["a.txt", "new.txt"],
    },
    {
      label: "a landing followed by checking main out again",
      earlierTurn: false,
      prepare: (_repo: string, worktreePath: string) => commitOwnWork(worktreePath),
      // HEAD's reflog then ends in "checkout: moving from older to main" with new
      // sha HEAD and old sha older's tip (not in HEAD); the branch reflog still
      // holds the landing.
      land: (repo: string) => {
        ffOnlyLanding(repo);
        git(repo, "checkout", "-q", "-b", "older", "main~1");
        commitOnMain(repo, "older-only.txt");
        git(repo, "checkout", "-q", "main");
      },
      files: ["a.txt", "new.txt"],
    },
    {
      label: "plain commits landed by update-ref from another worktree (the land queue)",
      earlierTurn: false,
      prepare: (_repo: string, worktreePath: string) => commitOwnWork(worktreePath),
      // Run from the worktree: only the branch reflog logs it, not the main checkout's HEAD.
      land: (repo: string) => {
        const worktreePath = git(repo, "worktree", "list", "--porcelain")
          .split("\n")
          .filter((line) => line.startsWith("worktree "))
          .map((line) => line.slice("worktree ".length))[1];
        const tip = git(worktreePath, "rev-parse", "HEAD");
        const before = git(repo, "rev-parse", "main");
        git(worktreePath, "update-ref", "-m", "land-queue b1", "refs/heads/main", tip, before);
      },
      files: ["a.txt", "new.txt"],
    },
  ])("a landing in the same turn keeps the landed files: $label", async (landing) => {
    const { workspace, dataDir, worktreePath } = makeRepo();
    const { processor, next } = makeProcessor(workspace, dataDir);
    const session = makeSession({ id: "sess-commit-land" });
    const active = makeActive(session);
    if (landing.earlierTurn) {
      writeFileSync(join(worktreePath, "b.txt"), "uncommitted\n");
      await settleTurn(processor, active, next, 1);
      expect(session.changeStats?.worktree).toMatchObject({ filesChanged: 1 });
      git(worktreePath, "checkout", "--", "b.txt");
    }

    // One turn: the work, then the landing; HEAD becomes the merge-base.
    landing.prepare(workspace.hostMount, worktreePath);
    landing.land(workspace.hostMount);
    expect(git(workspace.hostMount, "rev-parse", "main")).toBe(
      git(worktreePath, "rev-parse", "HEAD"),
    );
    await settleTurn(processor, active, next, 2);

    expect(session.changeStats?.worktree).toMatchObject({
      filesChanged: landing.files.length,
      changedFiles: landing.files,
    });

    // Removed after landing: the stored list answers.
    git(workspace.hostMount, "worktree", "remove", "--force", worktreePath);
    const listed = await makeTraceService(workspace, dataDir).getSessionWorktreeChanges(session);
    expect(listed).toMatchObject({
      kind: "ok",
      changes: {
        live: false,
        changedFileCount: landing.files.length,
        files: landing.files.map((path) => ({ path })),
      },
    });
  });

  it("a sync onto another worktree's landing never counts that worktree's work", async () => {
    const { workspace, dataDir, worktreePath } = makeRepo();
    const { processor, next } = makeProcessor(workspace, dataDir);
    const session = makeSession({ id: "sess-other-landing" });
    const active = makeActive(session);
    writeFileSync(join(worktreePath, "a.txt"), "one\ntwo\nthree\nfour\n");
    await settleTurn(processor, active, next, 1);

    // Another worktree commits and lands fast-forward; this one syncs onto main.
    const other = join(workspace.hostMount, "..", "other");
    git(workspace.hostMount, "worktree", "add", "-q", "-b", "other", other);
    writeFileSync(join(other, "other.txt"), "theirs\n");
    git(other, "add", "other.txt");
    git(other, "commit", "-q", "-m", "other work");
    git(workspace.hostMount, "merge", "-q", "--ff-only", "other");
    git(worktreePath, "merge", "-q", "--ff-only", "main");
    await settleTurn(processor, active, next, 2);

    expect(session.changeStats?.worktree).toMatchObject({
      filesChanged: 1,
      changedFiles: ["a.txt"],
    });
  });

  it("a reset back to the base stores zero instead of keeping the old count", async () => {
    const { workspace, dataDir, worktreePath } = makeRepo();
    const { processor, next } = makeProcessor(workspace, dataDir);
    const session = makeSession({ id: "sess-reset" });
    const active = makeActive(session);
    writeFileSync(join(worktreePath, "a.txt"), "changed\n");
    writeFileSync(join(worktreePath, "new-1.txt"), "x\n");
    writeFileSync(join(worktreePath, "new-2.txt"), "y\n");
    await settleTurn(processor, active, next, 1);
    expect(session.changeStats?.worktree?.filesChanged).toBe(3);

    git(worktreePath, "reset", "-q", "--hard");
    git(worktreePath, "clean", "-q", "-fd");
    await settleTurn(processor, active, next, 2);

    expect(session.changeStats?.worktree).toMatchObject({ filesChanged: 0, changedFiles: [] });
  });
});
