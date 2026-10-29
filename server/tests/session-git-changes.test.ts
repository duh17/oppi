import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
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
  const workspace = { id: "ws-git", name: "Repo", hostMount: repo } as Workspace;
  const worktreePath = join(managedWorktreesRoot(dataDir, workspace.id), "feature");
  mkdirSync(join(worktreePath, ".."), { recursive: true });
  git(repo, "worktree", "add", "-q", "-b", "feature", worktreePath);
  return { workspace, dataDir, worktreePath };
}

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "sess-git",
    workspaceId: "ws-git",
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
      ["diff", "ls-files", "merge-base", "rev-parse", "rev-parse", "worktree"].sort(),
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
    expect(secondSettle.sort()).toEqual(["diff", "ls-files", "rev-parse"]);
    expect(toolPhase).toBeGreaterThan(0);
  }, 15_000);

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
    // The summary the session list receives carries the same counts and paths.
    expect(buildSessionSummary(session).changeStats?.worktree).toMatchObject({
      filesChanged: 2,
      changedFiles: ["a.txt", "new.txt"],
      addedLines: 2,
      removedLines: 0,
    });

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
    expect(spawned.calls.map((args) => args[0]).sort()).toEqual(["diff", "ls-files", "rev-parse"]);
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
    const summarySent = next("session_summary");
    processor.updateSessionFromEvent("sess-landed", active, { type: "agent_settled" } as never);
    await summarySent;
    const stored = session.changeStats?.worktree;
    expect(stored?.filesChanged).toBe(1);

    git(workspace.hostMount, "merge", "-q", "--ff-only", "feature");
    git(workspace.hostMount, "worktree", "remove", worktreePath);

    // A later settle cannot read the worktree and keeps the stored value.
    const before = structuredClone(stored);
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
});
