import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { resolveSdkSessionCwd } from "../src/sdk-backend.js";
import {
  createWorkspaceWorktree,
  hasManagedWorkspaceWorktreeDirectory,
  listWorkspaceWorktrees,
  managedWorktreesRoot,
  previewWorkspaceWorktree,
  removeWorkspaceWorktree,
  resolveWorkspaceWorktree,
} from "../src/worktrees.js";
import type { CreateWorkspaceWorktreeRequest, Workspace } from "../src/types.js";

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

  it("creates Oppi-managed worktrees under the data dir", () => {
    const { root, workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-data-dir-"));
    roots.push(dataDir);

    const created = createWorkspaceWorktree(
      workspace,
      { branch: "feature/data-dir-root" },
      { dataDir },
    );

    expect(created.id).toMatch(/^wt_feature-data-dir-root-/);
    expect(created.path.startsWith(realpathSync(managedWorktreesRoot(dataDir, workspace.id)))).toBe(
      true,
    );
    expect(created.path.startsWith(join(root, ".pi", "worktrees"))).toBe(false);
    expect(created.branch).toBe("feature/data-dir-root");
    expect(created.managedByOppi).toBe(true);

    const listed = listWorkspaceWorktrees(workspace, { dataDir });
    expect(listed.find((worktree) => worktree.id === created.id)).toMatchObject({
      path: created.path,
      managedByOppi: true,
    });
  });

  it("treats an unreadable managed worktree root as occupied", () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-unreadable-root-"));
    roots.push(dataDir);
    const managedRoot = managedWorktreesRoot(dataDir, workspace.id);
    mkdirSync(dirname(managedRoot), { recursive: true });
    writeFileSync(managedRoot, "not a directory");

    expect(hasManagedWorkspaceWorktreeDirectory(dataDir, workspace.id)).toBe(true);
  });

  it("resolves SDK session cwd for data-dir managed worktrees", () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-sdk-cwd-"));
    roots.push(dataDir);
    const created = createWorkspaceWorktree(workspace, { branch: "feature/sdk-cwd" }, { dataDir });

    expect(resolveSdkSessionCwd(workspace, { worktreeId: created.id }, { dataDir })).toBe(
      created.path,
    );
  });

  it("rejects history-dependent branch shorthand when creating worktrees", () => {
    const { root, workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-branch-shorthand-"));
    roots.push(dataDir);
    git(root, ["branch", "feature/previous-checkout"]);
    git(root, ["checkout", "feature/previous-checkout"]);
    git(root, ["checkout", "main"]);

    expect(() => createWorkspaceWorktree(workspace, { branch: "@{-1}" }, { dataDir })).toThrow(
      "Invalid branch name",
    );
  });

  it("rejects malformed optional worktree create fields", () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-create-shape-"));
    roots.push(dataDir);

    expect(() =>
      createWorkspaceWorktree(
        workspace,
        { branch: "feature/bad-base", base: 123 } as unknown as CreateWorkspaceWorktreeRequest,
        { dataDir },
      ),
    ).toThrow("base must be a string");
    expect(() =>
      createWorkspaceWorktree(
        workspace,
        { branch: "feature/bad-path", path: [] } as unknown as CreateWorkspaceWorktreeRequest,
        { dataDir },
      ),
    ).toThrow("path must be a string");
  });

  it("rejects managed worktree ids reserved by retained session history", () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-reserved-history-"));
    roots.push(dataDir);
    const branch = "feature/retained-history";
    const created = createWorkspaceWorktree(workspace, { branch }, { dataDir });
    removeWorkspaceWorktree(workspace, { dataDir, worktreeId: created.id });

    expect(() =>
      createWorkspaceWorktree(
        workspace,
        { branch },
        {
          dataDir,
          reservedWorktreeIds: new Set([created.id]),
        },
      ),
    ).toThrow("Worktree id is still referenced by session history");
  });

  it("previews worktree integration without modifying either checkout", () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-preview-"));
    roots.push(dataDir);
    const created = createWorkspaceWorktree(workspace, { branch: "feature/preview" }, { dataDir });
    writeFileSync(join(created.path, "preview.txt"), "preview change\n");
    git(created.path, ["add", "preview.txt"]);
    git(created.path, ["commit", "-m", "preview change"]);

    const preview = previewWorkspaceWorktree(
      workspace,
      created.id,
      { into: "main", mode: "ff-only" },
      { dataDir },
    );

    expect(preview).toMatchObject({
      mode: "ff-only",
      alreadyMerged: false,
      fastForwardPossible: true,
      commitCount: 1,
      conflictCheck: "clean",
    });
    expect(preview.changedFiles).toContainEqual({ status: "A", path: "preview.txt" });
    expect(preview.commits[0]?.subject).toBe("preview change");
  });

  it("fails preview when changed files cannot be computed", () => {
    const { root, workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-preview-failure-"));
    roots.push(dataDir);

    git(root, ["checkout", "--orphan", "unrelated-history"]);
    git(root, ["rm", "-rf", "."]);
    writeFileSync(join(root, "unrelated.txt"), "unrelated history\n");
    git(root, ["add", "unrelated.txt"]);
    git(root, ["commit", "-m", "unrelated history"]);
    git(root, ["checkout", "main"]);
    const created = createWorkspaceWorktree(
      workspace,
      { branch: "unrelated-history" },
      { dataDir },
    );

    expect(() =>
      previewWorkspaceWorktree(workspace, created.id, { into: "main" }, { dataDir }),
    ).toThrow("Unable to compute changed files");
  });

  it("rejects managed worktree create paths outside the data dir root", () => {
    const { root, workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-outside-"));
    roots.push(dataDir);

    expect(() =>
      createWorkspaceWorktree(
        workspace,
        { branch: "feature/outside", path: join(root, "outside-worktree") },
        { dataDir },
      ),
    ).toThrow("data-dir worktrees root");
  });

  it("rejects custom managed worktree paths that collide with reserved ids", () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-reserved-id-"));
    roots.push(dataDir);

    const managedRoot = managedWorktreesRoot(dataDir, workspace.id);
    mkdirSync(managedRoot, { recursive: true });

    expect(() =>
      createWorkspaceWorktree(
        workspace,
        {
          branch: "feature/reserved-main",
          path: join(realpathSync(managedRoot), "main"),
        },
        { dataDir },
      ),
    ).toThrow("reserved worktree id");
  });

  it("removes only Oppi-managed data-dir worktrees", () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-remove-"));
    roots.push(dataDir);
    const projectLinked = listWorkspaceWorktrees(workspace).find((candidate) => !candidate.isMain)!;
    const created = createWorkspaceWorktree(
      workspace,
      { branch: "feature/remove-me" },
      { dataDir },
    );

    expect(() =>
      removeWorkspaceWorktree(workspace, {
        dataDir,
        worktreeId: projectLinked.id,
        force: true,
      }),
    ).toThrow("Only Oppi-managed data-dir worktrees can be removed");

    const removed = removeWorkspaceWorktree(workspace, {
      dataDir,
      worktreeId: created.id,
    });

    expect(removed.id).toBe(created.id);
    expect(existsSync(created.path)).toBe(false);
    expect(
      listWorkspaceWorktrees(workspace, { dataDir }).some((worktree) => worktree.id === created.id),
    ).toBe(false);
  });

  it("still requires force to remove dirty managed worktrees", () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-dirty-"));
    roots.push(dataDir);
    const created = createWorkspaceWorktree(workspace, { branch: "feature/dirty" }, { dataDir });
    writeFileSync(join(created.path, "dirty.txt"), "uncommitted\n");

    expect(() =>
      removeWorkspaceWorktree(workspace, {
        dataDir,
        worktreeId: created.id,
      }),
    ).toThrow("Worktree has uncommitted or untracked changes");
    expect(existsSync(created.path)).toBe(true);

    removeWorkspaceWorktree(workspace, {
      dataDir,
      worktreeId: created.id,
      force: true,
    });
    expect(existsSync(created.path)).toBe(false);
  });

  it("refuses to remove managed worktrees with active sessions", () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-active-"));
    roots.push(dataDir);
    const created = createWorkspaceWorktree(workspace, { branch: "feature/active" }, { dataDir });

    expect(() =>
      removeWorkspaceWorktree(workspace, {
        dataDir,
        worktreeId: created.id,
        force: true,
        activeSessionCount: 1,
      }),
    ).toThrow("Cannot remove a worktree with active sessions");
  });
});
