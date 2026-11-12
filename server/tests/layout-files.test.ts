/**
 * Layout files on disk: discovery limits, the checkout of each file, who wrote it, and the cards a
 * tracked write makes, live and again for a trace page.
 */
import { execSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { LayoutFiles } from "../src/layout-files.js";
import { managedWorktreesRoot } from "../src/worktrees.js";
import type { TraceEvent } from "../src/trace.js";
import type { Session, Workspace } from "../src/types.js";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function tempRoot(prefix: string): string {
  const root = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  roots.push(root);
  return root;
}

const GIT_ENV = { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" };
function git(cwd: string, command: string): void {
  execSync(`git -c user.email=t@t -c user.name=t ${command}`, {
    cwd,
    stdio: "ignore",
    env: GIT_ENV,
  });
}

function layout(title: string, extra = ""): string {
  return `{"v":1,"title":"${title}","root":{"pane":"chat","chat":"self"${extra}},"focus":"chat"}\n`;
}

interface Fixture {
  root: string;
  workspace: Workspace;
  files: LayoutFiles;
  changes: string[];
  clock: { now: number };
  /** Where an Oppi-managed worktree of the workspace goes. */
  worktreePath: (name: string) => string;
}

function seed(): Fixture {
  const root = tempRoot("oppi-layouts-");
  const dataDir = tempRoot("oppi-layouts-data-");
  const workspace = {
    id: "ws-1",
    name: "repo",
    hostMount: root,
    createdAt: 1,
    updatedAt: 1,
  } as Workspace;
  const changes: string[] = [];
  const clock = { now: 1_000_000 };
  const files = new LayoutFiles(
    {
      getWorkspace: (id) => (id === workspace.id ? workspace : undefined),
      getDataDir: () => dataDir,
    },
    { emitWorkspaceLayoutsChanged: (workspaceId) => changes.push(workspaceId) },
    () => clock.now,
  );
  return {
    root,
    workspace,
    files,
    changes,
    clock,
    worktreePath: (name) => join(managedWorktreesRoot(dataDir, workspace.id), name),
  };
}

function session(id: string, overrides: Partial<Session> = {}): Session {
  return {
    id,
    workspaceId: "ws-1",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  } as Session;
}

function writeLayout(root: string, name: string, content: string | Buffer): string {
  const folder = join(root, ".oppi", "layouts");
  mkdirSync(folder, { recursive: true });
  const path = join(folder, name);
  writeFileSync(path, content);
  return path;
}

/** What an agent's `write` tool leaves, and the call that did it. */
function trackedWrite(
  root: string,
  name: string,
  content: string,
): { args: Record<string, unknown> } {
  writeLayout(root, name, content);
  return { args: { path: `.oppi/layouts/${name}`, content } };
}

function trace(
  ...calls: { id: string; args: Record<string, unknown>; tool?: string; isError?: boolean }[]
): TraceEvent[] {
  return calls.flatMap((call) => [
    { id: call.id, type: "toolCall", timestamp: "t", tool: call.tool ?? "write", args: call.args },
    {
      id: `${call.id}-result`,
      type: "toolResult",
      timestamp: "t",
      toolCallId: call.id,
      isError: call.isError ?? false,
    },
  ]);
}

describe("layout discovery", () => {
  it("reads the first 64 valid names, refuses non-UTF-8, accepts a BOM, and stops at 16 KiB", async () => {
    const { root, workspace, files } = seed();
    for (let index = 0; index < 65; index += 1) {
      writeLayout(root, `l${String(index).padStart(2, "0")}.json`, layout(`Layout ${index}`));
    }
    writeLayout(root, "Bad Name.json", layout("ignored"));
    writeLayout(root, "notes.md", "not a layout");
    writeLayout(
      root,
      "a-bom.json",
      Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(layout("BOM"))]),
    );
    writeLayout(root, "a-latin.json", Buffer.from(layout("Caf\u00e9"), "latin1"));
    writeLayout(root, "a-large.json", layout("Large", `,"pad":"${" ".repeat(16 * 1024)}"`));

    const listed = await files.list(workspace);
    expect(listed).toHaveLength(64);
    expect(listed.map((row) => row.name).slice(0, 4)).toEqual([
      "a-bom",
      "a-large",
      "a-latin",
      "l00",
    ]);
    expect(listed.at(-1)?.name).toBe("l60");

    const byName = new Map(listed.map((row) => [row.name, row]));
    expect(byName.get("a-bom")).toMatchObject({
      title: "BOM",
      leafCount: 1,
      source: { kind: "folder" },
    });
    expect(byName.get("a-latin")?.problem?.code).toBe("notUtf8");
    const large = byName.get("a-large");
    expect(large?.problem?.code).toBe("tooLarge");
    expect(large?.hash).toBeUndefined();
  });

  it("ignores a file whose real path leaves the folder, and a linked folder", async () => {
    const { root, workspace, files } = seed();
    const outside = tempRoot("oppi-layouts-outside-");
    writeFileSync(join(outside, "elsewhere.json"), layout("Elsewhere"));
    writeLayout(root, "inside.json", layout("Inside"));
    symlinkSync(join(outside, "elsewhere.json"), join(root, ".oppi", "layouts", "escape.json"));
    symlinkSync(
      join(root, ".oppi", "layouts", "inside.json"),
      join(root, ".oppi", "layouts", "alias.json"),
    );

    expect((await files.list(workspace)).map((row) => row.name)).toEqual(["alias", "inside"]);
    expect(await files.read(workspace, "escape")).toBeNull();

    const linkedRoot = tempRoot("oppi-layouts-linked-");
    mkdirSync(join(linkedRoot, ".oppi"));
    symlinkSync(join(root, ".oppi", "layouts"), join(linkedRoot, ".oppi", "layouts"));
    expect(await files.list({ ...workspace, id: "ws-linked", hostMount: linkedRoot })).toEqual([]);
  });

  it("lists each checkout's files with that checkout, and reads one by worktree", async () => {
    const { root, workspace, files, worktreePath } = seed();
    git(root, "init -q -b main");
    writeLayout(root, "review.json", layout("Root review"));
    git(root, "add -A");
    git(root, "commit -qm init");
    const worktree = worktreePath("feature");
    git(root, `worktree add -q -b feature ${worktree}`);
    writeLayout(worktree, "review.json", layout("Worktree review"));

    const listed = await files.list(workspace);
    expect(listed.map((row) => [row.title, row.worktreeId === "main", row.source.kind])).toEqual([
      ["Root review", true, "repository"],
      ["Worktree review", false, "folder"],
    ]);
    const inWorktree = listed[1];
    const read = await files.read(workspace, "review", inWorktree?.worktreeId);
    expect(read?.file.state === "valid" && read.file.layout.title).toBe("Worktree review");
    expect(read?.checkout).toBe(inWorktree?.checkout);

    // A change to a committed file makes it the folder's again.
    writeLayout(root, "review.json", layout("Root review, edited"));
    expect((await files.read(workspace, "review"))?.source).toEqual({ kind: "folder" });
  });

  it("tells clients when a later look finds other files, not before 2 s", async () => {
    const { root, workspace, files, changes, clock } = seed();
    await files.list(workspace);
    expect(changes).toEqual([]);

    writeLayout(root, "review.json", layout("Review"));
    expect(await files.list(workspace)).toEqual([]);
    clock.now += 2_000;
    expect((await files.list(workspace)).map((row) => row.name)).toEqual(["review"]);
    expect(changes).toEqual(["ws-1"]);

    clock.now += 2_000;
    await files.list(workspace);
    expect(changes).toEqual(["ws-1"]);
  });
});

describe("layout cards", () => {
  it("cards a tracked write and names the session as the writer until the file changes", async () => {
    const { root, workspace, files, changes } = seed();
    const write = trackedWrite(root, "review.json", layout("Review"));

    const [proposal, ...rest] = await files.proposalsForToolCall(
      session("s1"),
      "call-1",
      "write",
      write.args,
    );
    expect(rest).toEqual([]);
    expect(proposal).toMatchObject({
      toolCallId: "call-1",
      workspaceId: "ws-1",
      worktreeId: "main",
      name: "review",
      path: ".oppi/layouts/review.json",
      file: { state: "valid", layout: { title: "Review" } },
    });
    expect(proposal?.changed).toBeUndefined();
    expect(changes).toEqual(["ws-1"]);
    expect((await files.read(workspace, "review"))?.source).toEqual({
      kind: "session",
      sessionId: "s1",
    });

    // A shell rewrite: no card, and the file is the folder's now.
    writeLayout(root, "review.json", layout("Review, by hand"));
    expect((await files.read(workspace, "review"))?.source).toEqual({ kind: "folder" });
  });

  it("makes no card for a shell write, a failed write, or a path outside a layouts folder", async () => {
    const { root, files } = seed();
    writeLayout(root, "review.json", layout("Review"));
    writeFileSync(join(root, "review.json"), layout("Not a layout path"));

    expect(
      await files.proposalsForToolCall(session("s1"), "call-1", "bash", {
        command: "cat > .oppi/layouts/review.json",
      }),
    ).toEqual([]);
    expect(
      await files.proposalsForToolCall(session("s1"), "call-2", "write", {
        path: "review.json",
        content: layout("Not a layout path"),
      }),
    ).toEqual([]);
    expect(
      await files.proposalsForTrace(
        session("s1"),
        trace({
          id: "call-3",
          args: { path: ".oppi/layouts/review.json", content: "x" },
          isError: true,
        }),
      ),
    ).toEqual([]);
  });

  it("derives one card per write on a trace page; only the newest still holds its file", async () => {
    const { root, files, clock } = seed();
    const first = trackedWrite(root, "review.json", layout("First"));
    await files.proposalsForToolCall(session("s1"), "call-1", "write", first.args);
    const second = trackedWrite(root, "review.json", layout("Second"));
    await files.proposalsForToolCall(session("s1"), "call-2", "write", second.args);
    const edit = {
      path: ".oppi/layouts/review.json",
      edits: [{ oldText: "Second", newText: "Third" }],
    };
    writeLayout(root, "review.json", layout("Third"));
    clock.now += 2_000;

    const cards = await files.proposalsForTrace(
      session("s1"),
      trace(
        { id: "call-1", args: first.args },
        { id: "call-2", args: second.args },
        { id: "call-3", tool: "edit", args: edit },
      ),
    );
    expect(cards.map((card) => [card.toolCallId, card.changed === true])).toEqual([
      ["call-1", true],
      ["call-2", true],
      ["call-3", false],
    ]);
    // Every card shows the file as it is now.
    expect(cards.map((card) => card.file.state === "valid" && card.file.layout.title)).toEqual([
      "Third",
      "Third",
      "Third",
    ]);
  });

  it("gives each of two sessions writing one file its card; the earlier one says it changed", async () => {
    const { root, workspace, files } = seed();
    const fromA = trackedWrite(root, "shared.json", layout("From A"));
    const [cardA] = await files.proposalsForToolCall(session("a"), "call-a", "write", fromA.args);
    const fromB = trackedWrite(root, "shared.json", layout("From B"));
    const [cardB] = await files.proposalsForToolCall(session("b"), "call-b", "write", fromB.args);
    expect(cardA?.file.state === "valid" && cardB?.file.state === "valid").toBe(true);
    expect(cardA && "hash" in cardA.file && cardA.file.hash).not.toBe(
      cardB && "hash" in cardB.file && cardB.file.hash,
    );
    expect((await files.read(workspace, "shared"))?.source).toEqual({
      kind: "session",
      sessionId: "b",
    });

    const [historyA] = await files.proposalsForTrace(
      session("a"),
      trace({ id: "call-a", args: fromA.args }),
    );
    const [historyB] = await files.proposalsForTrace(
      session("b"),
      trace({ id: "call-b", args: fromB.args }),
    );
    expect(historyA?.changed).toBe(true);
    expect(historyA?.file.state === "valid" && historyA.file.layout.title).toBe("From B");
    expect(historyB?.changed).toBeUndefined();
  });

  it("resolves a worktree session's relative path to its worktree, and an absolute one to the root", async () => {
    const { root, files, worktreePath } = seed();
    git(root, "init -q -b main");
    git(root, "commit -q --allow-empty -m init");
    const worktree = worktreePath("feature");
    git(root, `worktree add -q -b feature ${worktree}`);
    const inWorktree = trackedWrite(worktree, "review.json", layout("Worktree"));
    writeLayout(root, "review.json", layout("Root"));
    const worktreeSession = session("s1", { worktreeId: "feature" });

    const [relative] = await files.proposalsForToolCall(
      worktreeSession,
      "call-1",
      "write",
      inWorktree.args,
    );
    expect(relative?.worktreeId).toBe("feature");
    expect(relative?.file.state === "valid" && relative.file.layout.title).toBe("Worktree");

    const [absolute] = await files.proposalsForToolCall(worktreeSession, "call-2", "write", {
      path: join(root, ".oppi", "layouts", "review.json"),
      content: layout("Root"),
    });
    expect(absolute?.worktreeId).toBe("main");
    expect(absolute?.file.state === "valid" && absolute.file.layout.title).toBe("Root");
  });
});
