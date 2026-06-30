import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { listWorkspaceWorktrees, resolveWorkspaceWorktree } from "../src/worktrees.js";
import type { Workspace } from "../src/types.js";

const roots: string[] = [];

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function git(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

function makeGitWorkspace(): { root: string; linkedPath: string; workspace: Workspace } {
  const root = mkdtempSync(join(tmpdir(), "oppi-worktrees-test-"));
  roots.push(root);
  git(root, ["init", "--initial-branch=main"]);
  git(root, ["config", "user.email", "oppi-test@example.invalid"]);
  git(root, ["config", "user.name", "Oppi Test"]);
  writeFileSync(join(root, "README.md"), "main checkout\n");
  git(root, ["add", "README.md"]);
  git(root, ["commit", "-m", "initial"]);
  git(root, ["branch", "feature/worktree-support"]);

  const linkedPath = join(root, ".pi", "worktrees", "feature-worktree-support");
  mkdirSync(join(root, ".pi", "worktrees"), { recursive: true });
  roots.push(linkedPath);
  git(root, ["worktree", "add", linkedPath, "feature/worktree-support"]);

  return {
    root: realpathSync(root),
    linkedPath: realpathSync(linkedPath),
    workspace: {
      id: "ws-worktrees",
      name: "Worktrees",
      hostMount: root,
      systemPromptMode: "append",
      createdAt: Date.now(),
      updatedAt: Date.now(),
    },
  };
}

describe("workspace worktrees", () => {
  it("lists main checkout and linked git worktrees with stable ids", () => {
    const { root, linkedPath, workspace } = makeGitWorkspace();

    const worktrees = listWorkspaceWorktrees(workspace);

    expect(worktrees).toHaveLength(2);
    expect(worktrees[0]).toMatchObject({ id: "main", path: root, branch: "main", isMain: true });
    expect(worktrees[1]).toMatchObject({
      path: linkedPath,
      branch: "feature/worktree-support",
      isMain: false,
    });
    expect(worktrees[1]!.id).toMatch(/^wt_/);
  });

  it("lists only the main checkout and Oppi-managed linked worktrees", () => {
    const { root, workspace } = makeGitWorkspace();
    const externalPath = join(root, "..", "external-worktree");
    roots.push(externalPath);
    git(root, ["branch", "external/worktree"]);
    git(root, ["worktree", "add", externalPath, "external/worktree"]);

    const worktrees = listWorkspaceWorktrees(workspace);

    expect(worktrees).toHaveLength(2);
    expect(worktrees.map((worktree) => worktree.path)).not.toContain(realpathSync(externalPath));
  });

  it("resolves requested worktree ids back to the selected checkout path", () => {
    const { linkedPath, workspace } = makeGitWorkspace();
    const linked = listWorkspaceWorktrees(workspace).find((candidate) => !candidate.isMain)!;

    expect(resolveWorkspaceWorktree(workspace, linked.id)?.path).toBe(linkedPath);
    expect(resolveWorkspaceWorktree(workspace, undefined)?.id).toBe("main");
    expect(resolveWorkspaceWorktree(workspace, "missing")).toBeUndefined();
  });

  it("attaches session counts when provided", () => {
    const { workspace } = makeGitWorkspace();
    const linked = listWorkspaceWorktrees(workspace).find((candidate) => !candidate.isMain)!;

    const worktrees = listWorkspaceWorktrees(workspace, {
      sessionCountsByWorktreeId: new Map([
        ["main", 2],
        [linked.id, 3],
      ]),
    });

    expect(worktrees.find((worktree) => worktree.isMain)?.sessionCount).toBe(2);
    expect(worktrees.find((worktree) => worktree.id === linked.id)?.sessionCount).toBe(3);
  });
});
