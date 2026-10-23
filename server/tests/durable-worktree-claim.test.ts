import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ConversationId } from "@earendil-works/pi-durable";
import type { SessionHost } from "../src/durable-harness.js";
import { DurableThreads } from "../src/durable-threads.js";
import { Storage } from "../src/storage.js";

/** The one gated create: `provisionWorktree` parks inside it, so a spawn plans mid-create. */
const gate = vi.hoisted(() => {
  let entered!: () => void;
  const entry = new Promise<void>((resolve) => {
    entered = resolve;
  });
  let released!: () => void;
  const release = new Promise<void>((resolve) => {
    released = resolve;
  });
  let calls = 0;
  return {
    entry,
    release,
    openEntry: () => entered(),
    openRelease: () => released(),
    next: () => calls++,
  };
});

vi.mock("../src/worktrees.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/worktrees.js")>();
  return {
    ...actual,
    ensureWorkspaceWorktree: async (...args: Parameters<typeof actual.ensureWorkspaceWorktree>) => {
      // Only the first create parks; the later spawn's own create runs on.
      if (gate.next() === 0) {
        gate.openEntry();
        await gate.release;
      }
      return actual.ensureWorkspaceWorktree(...args);
    },
  };
});

const dirs: string[] = [];
afterEach(() => {
  gate.openRelease();
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function git(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

/** A git workspace whose spawning session is idle, and Oppi's thread host for it. */
async function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "oppi-worktree-claim-"));
  dirs.push(dir);
  const repo = join(dir, "repo");
  mkdirSync(repo, { recursive: true });
  git(repo, ["init", "--initial-branch=main"]);
  git(repo, ["config", "user.email", "oppi-test@example.invalid"]);
  git(repo, ["config", "user.name", "Oppi Test"]);
  writeFileSync(join(repo, "README.md"), "main checkout\n");
  git(repo, ["add", "README.md"]);
  git(repo, ["commit", "-m", "initial"]);
  const storage = new Storage(dir);
  const workspace = storage.createWorkspace({ name: "Claims", hostMount: repo });
  const parent = storage.createSession("Parent", "faux/faux-1");
  parent.workspaceId = workspace.id;
  parent.serverDurable = { storeId: "store", conversationId: 1 };
  storage.saveSession(parent);
  const threads = new DurableThreads({
    runtime: {} as never,
    storage,
    withIncomingWork: async () => {
      throw new Error("a worktree claim test never delivers work");
    },
    onCreated: () => {},
  });
  // Only what `planWorktree`/`provisionWorktree` read: the caller's runtime document.
  const host = {
    storeId: "store",
    open: async () => ({ harness: { snapshot: async () => undefined } }),
  } as unknown as SessionHost;
  return { repo, threads, sessions: threads.forCaller(host, 1 as ConversationId) };
}

describe("durable subagent worktree claims", () => {
  it("keeps a new branch held while its create runs, so a spawn planning then never shares it", async () => {
    const { sessions } = await fixture();
    const first = await sessions.planWorktree("new", "Twin", "call-a");
    expect(first).toMatchObject({ mode: "create", branch: "subagent/twin" });
    if (first.mode !== "create") throw new Error("expected a create plan");

    const creating = sessions.provisionWorktree(first, { call: "call-a", adopt: false });
    // A's create is in flight: no checkout exists and its branch is still held.
    await gate.entry;
    const second = await sessions.planWorktree("new", "Twin", "call-b");
    gate.openRelease();
    const a = await creating;

    // The second spawn planned its own branch, not the one A was making.
    expect(second).toMatchObject({ mode: "create", branch: "subagent/twin-2" });
    if (second.mode !== "create") throw new Error("expected a create plan");
    const b = await sessions.provisionWorktree(second, { call: "call-b", adopt: false });
    expect(b.branch).toBe("subagent/twin-2");
    expect(b.id).not.toBe(a.id);
    expect(b.path).not.toBe(a.path);
  });

  it("plans the next free branch for a rerun whose worktree was made before a crash", async () => {
    const { sessions } = await fixture();
    const planned = await sessions.planWorktree("new", "Crash", "call-a");
    if (planned.mode !== "create") throw new Error("expected a create plan");
    const orphan = await sessions.provisionWorktree(planned, { call: "call-a", adopt: false });
    // The commit that binds the child never happened. The rerun never adopts that checkout: it
    // plans the next free branch, and the clean untouched orphan is the daily cleanup's to take.
    const rerun = await sessions.planWorktree("new", "Crash", "call-a");
    expect(rerun).toMatchObject({ mode: "create", branch: "subagent/crash-2" });
    if (rerun.mode !== "create") throw new Error("expected a create plan");
    const own = await sessions.provisionWorktree(rerun, { call: "call-a", adopt: false });
    expect(own.id).not.toBe(orphan.id);
    expect(own.branch).toBe("subagent/crash-2");
  });

  it("creates or adopts a named branch, and never hands a new spawn one it did not make", async () => {
    const { sessions } = await fixture();
    const made = await sessions.planWorktree("new", "Twin", "call-a");
    if (made.mode !== "create") throw new Error("expected a create plan");
    const mine = await sessions.provisionWorktree(made, { call: "call-a", adopt: false });

    // A `{ branch }` request still adopts the branch's existing checkout.
    const named = await sessions.planWorktree({ branch: mine.branch! }, "Other", "call-b");
    const adopted = await sessions.provisionWorktree(named, { call: "call-b", adopt: true });
    expect(adopted.id).toBe(mine.id);

    // A `"new"` spawn with the same name plans the next free branch instead of adopting.
    const next = await sessions.planWorktree("new", "Twin", "call-c");
    expect(next).toMatchObject({ mode: "create", branch: "subagent/twin-2" });
    if (next.mode !== "create") throw new Error("expected a create plan");
    const own = await sessions.provisionWorktree(next, { call: "call-c", adopt: false });
    expect(own.id).not.toBe(mine.id);

    // A plan for a branch that already has a checkout refuses rather than sharing it.
    const repeated = await sessions.planWorktree({ branch: mine.branch! }, "Again", "call-d");
    await expect(
      sessions.provisionWorktree(repeated, { call: "call-d", adopt: false }),
    ).rejects.toThrow("appeared while this spawn was planning");
  });
});
