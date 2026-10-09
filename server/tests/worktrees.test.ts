import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { resolveSdkSessionCwdAsync } from "../src/sdk-backend.js";
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

function installSlowWorktreeRemove(bin: string): void {
  const realGit = execFileSync("/bin/sh", ["-c", "command -v git"], { encoding: "utf8" }).trim();
  writeFileSync(
    join(bin, "git"),
    `#!/bin/sh
if [ "$1" = "worktree" ] && [ "$2" = "remove" ]; then
  sleep 1
fi
exec ${JSON.stringify(realGit)} "$@"
`,
  );
  chmodSync(join(bin, "git"), 0o755);
}

function installCreateRemovalRaceGit(bin: string, cwd: string, stateDir: string): void {
  const realGit = execFileSync("/bin/sh", ["-c", "command -v git"], { encoding: "utf8" }).trim();
  const state = JSON.stringify(stateDir);
  writeFileSync(
    join(bin, "git"),
    `#!/bin/sh
expected=${JSON.stringify(cwd)}
expected_p=$(cd "$expected" && pwd -P)
pwd_p=$(pwd -P)
if [ "$pwd_p" = "$expected_p" ] && [ "$1" = "worktree" ] && [ "$2" = "list" ]; then
  nfile=${state}/list-count
  n=$(cat "$nfile" 2>/dev/null || echo 0)
  n=$((n + 1))
  printf '%s\n' "$n" > "$nfile"
  if [ "$n" = "1" ]; then
    touch ${state}/list-started
    while [ ! -f ${state}/release-list ]; do
      sleep 0.02
    done
  fi
fi
if [ "$pwd_p" = "$expected_p" ] && [ "$1" = "worktree" ] && [ "$2" = "remove" ]; then
  touch ${state}/remove-started
  while [ ! -f ${state}/release-remove ]; do
    sleep 0.02
  done
fi
if [ "$pwd_p" = "$expected_p" ] && [ "$1" = "worktree" ] && [ "$2" = "add" ]; then
  printf '%s\n' "$*" >> ${state}/add-log
fi
exec ${JSON.stringify(realGit)} "$@"
`,
  );
  chmodSync(join(bin, "git"), 0o755);
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

describe("workspace worktrees", async () => {
  it("lists main checkout and linked git worktrees with stable ids", async () => {
    const { root, linkedPath, workspace } = makeGitWorkspace();

    const worktrees = await listWorkspaceWorktrees(workspace);

    expect(worktrees).toHaveLength(2);
    expect(worktrees[0]).toMatchObject({ id: "main", path: root, branch: "main", isMain: true });
    expect(worktrees[1]).toMatchObject({
      path: linkedPath,
      branch: "feature/worktree-support",
      isMain: false,
    });
    expect(worktrees[1]!.id).toMatch(/^wt_/);
  });

  it("lists only the main checkout and Oppi-managed linked worktrees", async () => {
    const { root, workspace } = makeGitWorkspace();
    const externalPath = join(root, "..", "external-worktree");
    roots.push(externalPath);
    git(root, ["branch", "external/worktree"]);
    git(root, ["worktree", "add", externalPath, "external/worktree"]);

    const worktrees = await listWorkspaceWorktrees(workspace);

    expect(worktrees).toHaveLength(2);
    expect(worktrees.map((worktree) => worktree.path)).not.toContain(realpathSync(externalPath));
  });

  it("resolves requested worktree ids back to the selected checkout path", async () => {
    const { linkedPath, workspace } = makeGitWorkspace();
    const linked = (await listWorkspaceWorktrees(workspace)).find(
      (candidate) => !candidate.isMain,
    )!;

    expect((await resolveWorkspaceWorktree(workspace, linked.id))?.path).toBe(linkedPath);
    expect((await resolveWorkspaceWorktree(workspace, undefined))?.id).toBe("main");
    expect(await resolveWorkspaceWorktree(workspace, "missing")).toBeUndefined();
  });

  it("attaches session counts when provided", async () => {
    const { workspace } = makeGitWorkspace();
    const linked = (await listWorkspaceWorktrees(workspace)).find(
      (candidate) => !candidate.isMain,
    )!;

    const worktrees = await listWorkspaceWorktrees(workspace, {
      sessionCountsByWorktreeId: new Map([
        ["main", 2],
        [linked.id, 3],
      ]),
    });

    expect(worktrees.find((worktree) => worktree.isMain)?.sessionCount).toBe(2);
    expect(worktrees.find((worktree) => worktree.id === linked.id)?.sessionCount).toBe(3);
  });

  it("creates Oppi-managed worktrees under the data dir", async () => {
    const { root, workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-data-dir-"));
    roots.push(dataDir);

    const created = await createWorkspaceWorktree(
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

    const listed = await listWorkspaceWorktrees(workspace, { dataDir });
    expect(listed.find((worktree) => worktree.id === created.id)).toMatchObject({
      path: created.path,
      managedByOppi: true,
    });
  });

  it("treats an unreadable managed worktree root as occupied", async () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-unreadable-root-"));
    roots.push(dataDir);
    const managedRoot = managedWorktreesRoot(dataDir, workspace.id);
    mkdirSync(dirname(managedRoot), { recursive: true });
    writeFileSync(managedRoot, "not a directory");

    expect(hasManagedWorkspaceWorktreeDirectory(dataDir, workspace.id)).toBe(true);
  });

  it("resolves SDK session cwd for data-dir managed worktrees", async () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-sdk-cwd-"));
    roots.push(dataDir);
    const created = await createWorkspaceWorktree(
      workspace,
      { branch: "feature/sdk-cwd" },
      { dataDir },
    );

    expect(
      await resolveSdkSessionCwdAsync(workspace, { worktreeId: created.id }, { dataDir }),
    ).toBe(created.path);
  });

  it("rejects history-dependent branch shorthand when creating worktrees", async () => {
    const { root, workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-branch-shorthand-"));
    roots.push(dataDir);
    git(root, ["branch", "feature/previous-checkout"]);
    git(root, ["checkout", "feature/previous-checkout"]);
    git(root, ["checkout", "main"]);

    await expect(
      createWorkspaceWorktree(workspace, { branch: "@{-1}" }, { dataDir }),
    ).rejects.toThrow("Invalid branch name");
  });

  it("rejects malformed optional worktree create fields", async () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-create-shape-"));
    roots.push(dataDir);

    await expect(
      createWorkspaceWorktree(
        workspace,
        { branch: "feature/bad-base", base: 123 } as unknown as CreateWorkspaceWorktreeRequest,
        { dataDir },
      ),
    ).rejects.toThrow("base must be a string");
    await expect(
      createWorkspaceWorktree(
        workspace,
        { branch: "feature/bad-path", path: [] } as unknown as CreateWorkspaceWorktreeRequest,
        { dataDir },
      ),
    ).rejects.toThrow("path must be a string");
  });

  it("rejects managed worktree ids reserved by retained session history", async () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-reserved-history-"));
    roots.push(dataDir);
    const branch = "feature/retained-history";
    const created = await createWorkspaceWorktree(workspace, { branch }, { dataDir });
    await removeWorkspaceWorktree(workspace, { dataDir, worktreeId: created.id });

    await expect(
      createWorkspaceWorktree(
        workspace,
        { branch },
        {
          dataDir,
          reservedWorktreeIds: new Set([created.id]),
        },
      ),
    ).rejects.toThrow("Worktree id is still referenced by session history");
  });

  it("previews worktree integration without modifying either checkout", async () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-preview-"));
    roots.push(dataDir);
    const created = await createWorkspaceWorktree(
      workspace,
      { branch: "feature/preview" },
      { dataDir },
    );
    writeFileSync(join(created.path, "preview.txt"), "preview change\n");
    git(created.path, ["add", "preview.txt"]);
    git(created.path, ["commit", "-m", "preview change"]);

    const preview = await previewWorkspaceWorktree(
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

  it("fails preview when changed files cannot be computed", async () => {
    const { root, workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-preview-failure-"));
    roots.push(dataDir);

    git(root, ["checkout", "--orphan", "unrelated-history"]);
    git(root, ["rm", "-rf", "."]);
    writeFileSync(join(root, "unrelated.txt"), "unrelated history\n");
    git(root, ["add", "unrelated.txt"]);
    git(root, ["commit", "-m", "unrelated history"]);
    git(root, ["checkout", "main"]);
    const created = await createWorkspaceWorktree(
      workspace,
      { branch: "unrelated-history" },
      { dataDir },
    );

    await expect(
      previewWorkspaceWorktree(workspace, created.id, { into: "main" }, { dataDir }),
    ).rejects.toThrow("Unable to compute changed files");
  });

  it("rejects managed worktree create paths outside the data dir root", async () => {
    const { root, workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-outside-"));
    roots.push(dataDir);

    await expect(
      createWorkspaceWorktree(
        workspace,
        { branch: "feature/outside", path: join(root, "outside-worktree") },
        { dataDir },
      ),
    ).rejects.toThrow("data-dir worktrees root");
  });

  it("rejects custom managed worktree paths that collide with reserved ids", async () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-reserved-id-"));
    roots.push(dataDir);

    const managedRoot = managedWorktreesRoot(dataDir, workspace.id);
    mkdirSync(managedRoot, { recursive: true });

    await expect(
      createWorkspaceWorktree(
        workspace,
        {
          branch: "feature/reserved-main",
          path: join(realpathSync(managedRoot), "main"),
        },
        { dataDir },
      ),
    ).rejects.toThrow("reserved worktree id");
  });

  it("removes only Oppi-managed data-dir worktrees", async () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-remove-"));
    roots.push(dataDir);
    const projectLinked = (await listWorkspaceWorktrees(workspace)).find(
      (candidate) => !candidate.isMain,
    )!;
    const created = await createWorkspaceWorktree(
      workspace,
      { branch: "feature/remove-me" },
      { dataDir },
    );

    await expect(
      removeWorkspaceWorktree(workspace, {
        dataDir,
        worktreeId: projectLinked.id,
        force: true,
      }),
    ).rejects.toThrow("Only Oppi-managed data-dir worktrees can be removed");

    const removed = await removeWorkspaceWorktree(workspace, {
      dataDir,
      worktreeId: created.id,
    });

    expect(removed.id).toBe(created.id);
    expect(existsSync(created.path)).toBe(false);
    expect(
      (await listWorkspaceWorktrees(workspace, { dataDir })).some(
        (worktree) => worktree.id === created.id,
      ),
    ).toBe(false);
  });

  it("still requires force to remove dirty managed worktrees", async () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-dirty-"));
    roots.push(dataDir);
    const created = await createWorkspaceWorktree(
      workspace,
      { branch: "feature/dirty" },
      { dataDir },
    );
    writeFileSync(join(created.path, "dirty.txt"), "uncommitted\n");

    await expect(
      removeWorkspaceWorktree(workspace, {
        dataDir,
        worktreeId: created.id,
      }),
    ).rejects.toThrow("Worktree has uncommitted or untracked changes");
    expect(existsSync(created.path)).toBe(true);
    // A refused removal leaves the tree in the catalog.
    expect(
      (await listWorkspaceWorktrees(workspace, { dataDir })).some(
        (worktree) => worktree.id === created.id,
      ),
    ).toBe(true);

    await removeWorkspaceWorktree(workspace, {
      dataDir,
      worktreeId: created.id,
      force: true,
    });
    expect(existsSync(created.path)).toBe(false);
  });

  it("refuses to remove managed worktrees with active sessions", async () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-active-"));
    roots.push(dataDir);
    const created = await createWorkspaceWorktree(
      workspace,
      { branch: "feature/active" },
      { dataDir },
    );

    await expect(
      removeWorkspaceWorktree(workspace, {
        dataDir,
        worktreeId: created.id,
        force: true,
        activeSessionCount: 1,
      }),
    ).rejects.toThrow("Cannot remove a worktree with active sessions");
  });

  it("hides a worktree from the catalog while its removal runs and rejects a second removal", async () => {
    const { workspace } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-pending-"));
    roots.push(dataDir);
    const created = await createWorkspaceWorktree(
      workspace,
      { branch: "feature/pending" },
      { dataDir },
    );
    const bin = mkdtempSync(join(tmpdir(), "oppi-worktrees-slow-remove-"));
    roots.push(bin);
    installSlowWorktreeRemove(bin);
    const previousPath = process.env.PATH;
    process.env.PATH = `${bin}${delimiter}${previousPath ?? ""}`;
    try {
      const removal = removeWorkspaceWorktree(workspace, { dataDir, worktreeId: created.id });
      await vi.waitFor(async () => {
        expect(await resolveWorkspaceWorktree(workspace, created.id, { dataDir })).toBeUndefined();
      });
      await expect(
        removeWorkspaceWorktree(workspace, { dataDir, worktreeId: created.id }),
      ).rejects.toMatchObject({
        statusCode: 409,
        message: "Worktree removal is already in progress",
      });
      await expect(
        createWorkspaceWorktree(workspace, { branch: "feature/pending" }, { dataDir }),
      ).rejects.toMatchObject({ statusCode: 409, message: "Worktree id already exists" });

      expect((await removal).id).toBe(created.id);
      expect(existsSync(created.path)).toBe(false);
    } finally {
      process.env.PATH = previousPath;
    }
  });

  it("does not hide another workspace when a removal id is missing or in progress", async () => {
    const left = makeGitWorkspace();
    const right = makeGitWorkspace();
    right.workspace = { ...right.workspace, id: "ws-worktrees-b" };
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-pending-scope-"));
    roots.push(dataDir);
    const rightTree = await createWorkspaceWorktree(
      right.workspace,
      { branch: "fix/shared" },
      { dataDir },
    );
    await expect(
      removeWorkspaceWorktree(left.workspace, { dataDir, worktreeId: rightTree.id }),
    ).rejects.toMatchObject({ statusCode: 404, message: "Worktree not found" });
    expect(
      await resolveWorkspaceWorktree(right.workspace, rightTree.id, { dataDir }),
    ).toBeDefined();

    const leftTree = await createWorkspaceWorktree(
      left.workspace,
      { branch: "fix/shared" },
      { dataDir },
    );
    expect(leftTree.id).toBe(rightTree.id);
    const bin = mkdtempSync(join(tmpdir(), "oppi-worktrees-slow-scope-"));
    roots.push(bin);
    installSlowWorktreeRemove(bin);
    const previousPath = process.env.PATH;
    process.env.PATH = `${bin}${delimiter}${previousPath ?? ""}`;
    try {
      const removal = removeWorkspaceWorktree(left.workspace, {
        dataDir,
        worktreeId: leftTree.id,
      });
      await vi.waitFor(async () => {
        expect(
          await resolveWorkspaceWorktree(left.workspace, leftTree.id, { dataDir }),
        ).toBeUndefined();
      });
      expect(
        await resolveWorkspaceWorktree(right.workspace, rightTree.id, { dataDir }),
      ).toMatchObject({ id: rightTree.id });
      await expect(
        removeWorkspaceWorktree(right.workspace, { dataDir, worktreeId: rightTree.id }),
      ).resolves.toMatchObject({ id: rightTree.id });
      expect((await removal).id).toBe(leftTree.id);
    } finally {
      process.env.PATH = previousPath;
    }
  });

  it("does not add a worktree when removal claims the key during the catalog check", async () => {
    const { workspace, root } = makeGitWorkspace();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-create-race-"));
    roots.push(dataDir);
    const created = await createWorkspaceWorktree(
      workspace,
      { branch: "feature/create-race" },
      { dataDir },
    );
    const stateDir = mkdtempSync(join(tmpdir(), "oppi-worktrees-create-race-state-"));
    roots.push(stateDir);
    const bin = mkdtempSync(join(tmpdir(), "oppi-worktrees-create-race-bin-"));
    roots.push(bin);
    installCreateRemovalRaceGit(bin, root, stateDir);
    const previousPath = process.env.PATH;
    process.env.PATH = `${bin}${delimiter}${previousPath ?? ""}`;
    try {
      const creating = createWorkspaceWorktree(
        workspace,
        { branch: "feature/create-race" },
        { dataDir },
      );
      await vi.waitFor(() => {
        expect(existsSync(join(stateDir, "list-started"))).toBe(true);
      });
      const removal = removeWorkspaceWorktree(workspace, {
        dataDir,
        worktreeId: created.id,
        force: true,
      });
      await vi.waitFor(async () => {
        expect(await resolveWorkspaceWorktree(workspace, created.id, { dataDir })).toBeUndefined();
      });
      writeFileSync(join(stateDir, "release-list"), "1");
      await expect(creating).rejects.toMatchObject({
        statusCode: 409,
        message: "Worktree id already exists",
      });
      expect(existsSync(join(stateDir, "add-log"))).toBe(false);
      writeFileSync(join(stateDir, "release-remove"), "1");
      await expect(removal).resolves.toMatchObject({ id: created.id });
    } finally {
      process.env.PATH = previousPath;
    }
  });

  it("lets the event loop run while git lists worktrees", async () => {
    const bin = mkdtempSync(join(tmpdir(), "oppi-worktrees-slow-git-"));
    roots.push(bin);
    const gitPath = join(bin, "git");
    writeFileSync(
      gitPath,
      `#!/bin/sh
sleep 0.4
if [ "$1" = "rev-parse" ]; then
  printf '%s\\n' "$PWD"
  exit 0
fi
if [ "$1" = "worktree" ]; then
  printf 'worktree %s\\nHEAD abcdef\\nbranch refs/heads/main\\n' "$PWD"
  exit 0
fi
exit 0
`,
    );
    chmodSync(gitPath, 0o755);
    const root = mkdtempSync(join(tmpdir(), "oppi-worktrees-slow-repo-"));
    roots.push(root);
    mkdirSync(join(root, ".git"));
    const workspace = {
      id: "ws-slow-git",
      name: "Slow git",
      hostMount: root,
      systemPromptMode: "append" as const,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    const previousPath = process.env.PATH;
    process.env.PATH = `${bin}:${previousPath ?? ""}`;
    try {
      const pending = listWorkspaceWorktrees(workspace);
      const raced = await Promise.race([
        pending.then(() => "done"),
        new Promise((resolve) => setTimeout(() => resolve("tick"), 50)),
      ]);
      expect(raced).toBe("tick");
      await pending;
    } finally {
      process.env.PATH = previousPath;
    }
  });
});
