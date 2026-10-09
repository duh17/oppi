/**
 * Sandbox workspace mounts are writable from inside the VM, so their `.git` is
 * attacker-controlled. Every case builds an armed repository (config, attributes,
 * and hooks that each write a marker file), runs the host git entry points
 * against it, and asserts nothing executed. The host-trust controls prove the
 * fixture is armed: without them a green "no marker" would prove nothing.
 */

import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { getCommitDetail, getCommitFileDiff, getCommitLog } from "../src/git-commits.js";
import {
  execGit,
  gitTrustForWorkspace,
  HOST_GIT_TRUST,
  isGitRepository,
  SandboxGitRefusedError,
} from "../src/git-safe.js";
import { getGitStatus, getWorkspaceGitSummary } from "../src/git-status.js";
import type { Workspace } from "../src/types.js";
import { buildWorkspaceReviewDiff } from "../src/workspace-review-diff.js";
import {
  createWorkspaceWorktree,
  listWorkspaceWorktrees,
  previewWorkspaceWorktree,
  removeWorkspaceWorktree,
} from "../src/worktrees.js";

const roots: string[] = [];

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function tempDir(prefix: string): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  roots.push(dir);
  return dir;
}

function git(cwd: string, args: string[]): string {
  return execFileSync("git", ["-c", "core.hooksPath=/dev/null", ...args], {
    cwd,
    encoding: "utf8",
    env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" },
  }).trim();
}

interface ArmedRepo {
  mount: string;
  marker: string;
  commitSha: string;
}

/** A mount whose repository tries every execution vector the VM could plant. */
function armedRepo(options: { infoAttributes?: boolean } = {}): ArmedRepo {
  const scratch = tempDir("oppi-git-safe-");
  const mount = join(scratch, "mount");
  mkdirSync(mount, { recursive: true });
  const marker = join(scratch, "marker");

  const probe = join(scratch, "probe.sh");
  writeFileSync(probe, `#!/bin/sh\necho "probe $*" >> ${JSON.stringify(marker)}\nexit 0\n`);
  chmodSync(probe, 0o755);
  const passthrough = join(scratch, "passthrough.sh");
  writeFileSync(
    passthrough,
    `#!/bin/sh\necho "filter $*" >> ${JSON.stringify(marker)}\nexec cat\n`,
  );
  chmodSync(passthrough, 0o755);
  const hooks = join(scratch, "hooks");
  mkdirSync(hooks);
  for (const hook of ["post-checkout", "reference-transaction", "post-commit"]) {
    writeFileSync(
      join(hooks, hook),
      `#!/bin/sh\necho "hook ${hook}" >> ${JSON.stringify(marker)}\n`,
    );
    chmodSync(join(hooks, hook), 0o755);
  }

  git(mount, ["init", "--initial-branch=main"]);
  git(mount, ["config", "user.email", "t@example.invalid"]);
  git(mount, ["config", "user.name", "T"]);
  writeFileSync(join(mount, "a.txt"), "one\n");
  writeFileSync(join(mount, ".gitattributes"), "*.txt filter=evil diff=evil\n");
  git(mount, ["add", "."]);
  git(mount, ["commit", "-m", "first"]);
  git(mount, ["branch", "base"]);
  git(mount, ["branch", "--set-upstream-to=base"]);
  writeFileSync(join(mount, "a.txt"), "two\n");
  git(mount, ["commit", "-am", "second"]);
  const commitSha = git(mount, ["rev-parse", "HEAD"]);
  git(mount, ["branch", "feature"]);

  // Armed after setup so the setup commands above cannot trip the markers.
  const config = (key: string, value: string): void => git(mount, ["config", key, value]);
  config("core.fsmonitor", probe);
  config("core.hooksPath", hooks);
  config("diff.external", probe);
  config("diff.evil.textconv", passthrough);
  config("diff.evil.command", probe);
  config("filter.evil.clean", passthrough);
  config("filter.evil.smudge", passthrough);
  config("core.pager", probe);
  config("core.sshCommand", probe);
  config("credential.helper", `!${probe}`);
  if (options.infoAttributes !== false) {
    writeFileSync(join(mount, ".git", "info", "attributes"), "*.md filter=evil diff=evil\n");
  }
  writeFileSync(join(mount, "b.md"), "tracked-by-info-attributes\n");

  // Same size, newer mtime: status and diff must compare content, which runs the clean filter.
  writeFileSync(join(mount, "a.txt"), "six\n");
  const future = new Date(Date.now() + 5000);
  utimesSync(join(mount, "a.txt"), future, future);
  return { mount, marker, commitSha };
}

function sandboxWorkspace(mount: string, id = "ws-sandbox"): Workspace {
  return {
    id,
    name: id,
    runtime: "sandbox",
    hostMount: mount,
    systemPromptMode: "append",
    createdAt: 0,
    updatedAt: 0,
  };
}

function hostWorkspace(mount: string): Workspace {
  return { ...sandboxWorkspace(mount, "ws-host"), runtime: "host" };
}

function markerLines(marker: string): string[] {
  return existsSync(marker) ? readFileSync(marker, "utf8").split("\n").filter(Boolean) : [];
}

describe("sandbox git: repository-controlled execution", () => {
  it("control: host trust runs the planted config, so the fixture is armed", async () => {
    const { mount, marker, commitSha } = armedRepo();
    const trust = gitTrustForWorkspace(hostWorkspace(mount));
    expect(trust).toBe(HOST_GIT_TRUST);

    await getGitStatus(mount, trust);
    await getCommitFileDiff(mount, trust, commitSha, "a.txt", "ws");
    await buildWorkspaceReviewDiff({
      workspaceId: "ws",
      workspaceRoot: mount,
      trust,
      path: "a.txt",
    });

    const lines = markerLines(marker);
    expect(lines.some((line) => line.startsWith("probe"))).toBe(true);
    expect(lines.some((line) => line.startsWith("filter"))).toBe(true);
  });

  it("catalog summary, status, and commit browsing execute nothing and still answer", async () => {
    const { mount, marker, commitSha } = armedRepo();
    const trust = gitTrustForWorkspace(sandboxWorkspace(mount));

    const summary = await getWorkspaceGitSummary(mount, trust);
    expect(summary).toEqual({ isGitRepo: true, changedCount: 2, ahead: 1, behind: 0 });

    const status = await getGitStatus(mount, trust);
    expect(status).toMatchObject({
      isGitRepo: true,
      branch: "main",
      dirtyCount: 1,
      untrackedCount: 1,
      ahead: 1,
      behind: 0,
      // a.txt (+1 -1) plus the untracked b.md line count.
      addedLines: 3,
      removedLines: 1,
    });
    expect(status.recentCommits.map((commit) => commit.message)).toEqual(["second", "first"]);
    expect(status.files.map((file) => [file.status, file.path]).sort()).toEqual([
      [" M", "a.txt"],
      ["??", "b.md"],
    ]);

    const log = await getCommitLog(mount, trust, 0, 10);
    expect(log).toMatchObject({ total: 2, hasMore: false });
    expect(log.commits.map((commit) => commit.message)).toEqual(["second", "first"]);

    const detail = await getCommitDetail(mount, trust, commitSha);
    expect(detail.files).toEqual([{ path: "a.txt", status: "M", addedLines: 1, removedLines: 1 }]);

    const commitDiff = await getCommitFileDiff(mount, trust, commitSha, "a.txt", "ws");
    expect(commitDiff).toMatchObject({ baselineText: "one\n", currentText: "two\n" });

    const reviewDiff = await buildWorkspaceReviewDiff({
      workspaceId: "ws",
      workspaceRoot: mount,
      trust,
      path: "a.txt",
    });
    expect(reviewDiff).toMatchObject({ baselineText: "two\n", currentText: "six\n" });

    expect(markerLines(marker)).toEqual([]);
  });

  it("does not execute hooks, filters, or fsmonitor when managing worktrees", async () => {
    const { mount, marker } = armedRepo({ infoAttributes: false });
    const workspace = sandboxWorkspace(mount);
    const dataDir = tempDir("oppi-git-safe-data-");

    const created = await createWorkspaceWorktree(workspace, { branch: "feature" }, { dataDir });
    expect(created).toMatchObject({ branch: "feature", isGitRepo: true, managedByOppi: true });
    expect(markerLines(marker)).toEqual([]);

    // Commit on the worktree so preview has something to compare. The setup git
    // runs under the armed config, so clear the marker afterwards.
    writeFileSync(join(created.path, "c.txt"), "new\n");
    git(created.path, ["add", "c.txt"]);
    git(created.path, ["commit", "-m", "on feature"]);
    rmSync(marker, { force: true });

    const trust = gitTrustForWorkspace(workspace);
    const worktreeStatus = await getGitStatus(created.path, trust);
    expect(worktreeStatus).toMatchObject({ isGitRepo: true, branch: "feature", dirtyCount: 0 });
    expect(worktreeStatus.recentCommits[0]?.message).toBe("on feature");

    const preview = await previewWorkspaceWorktree(
      workspace,
      created.id,
      { into: "main", mode: "merge" },
      { dataDir },
    );
    expect(preview).toMatchObject({
      commitCount: 1,
      changedFiles: [{ status: "A", path: "c.txt" }],
      conflictCheck: "clean",
    });

    const listed = await listWorkspaceWorktrees(workspace, { dataDir });
    expect(listed.map((worktree) => worktree.branch).sort()).toEqual(["feature", "main"]);

    await removeWorkspaceWorktree(workspace, { dataDir, worktreeId: created.id });
    expect(existsSync(created.path)).toBe(false);

    expect(markerLines(marker)).toEqual([]);
  });

  it("control: host-runtime worktree creation still runs the owner's hooks", async () => {
    const { mount, marker } = armedRepo();
    const dataDir = tempDir("oppi-git-safe-data-");

    await createWorkspaceWorktree(hostWorkspace(mount), { branch: "feature" }, { dataDir });

    expect(markerLines(marker)).toContain("hook post-checkout");
  });

  it("refuses worktree administration while info/attributes carries rules", async () => {
    const { mount, marker } = armedRepo();
    const workspace = sandboxWorkspace(mount);
    const dataDir = tempDir("oppi-git-safe-data-");

    await expect(
      createWorkspaceWorktree(workspace, { branch: "feature" }, { dataDir }),
    ).rejects.toMatchObject({ statusCode: 409 });
    expect(markerLines(marker)).toEqual([]);
  });

  it("ignores a core.worktree that points outside the mount", async () => {
    const { mount } = armedRepo();
    const outside = tempDir("oppi-git-safe-outside-");
    writeFileSync(join(outside, "host-secret.txt"), "host data\n");
    git(mount, ["config", "core.worktree", outside]);

    const status = await getGitStatus(mount, gitTrustForWorkspace(sandboxWorkspace(mount)));

    expect(status.files.map((file) => file.path).sort()).toEqual(["a.txt", "b.md"]);
  });

  it("does not let a submodule's own armed repository run during status", async () => {
    const { mount, marker } = armedRepo({ infoAttributes: false });
    const source = tempDir("oppi-git-safe-sub-");
    git(source, ["init", "--initial-branch=main"]);
    git(source, ["config", "user.email", "t@example.invalid"]);
    git(source, ["config", "user.name", "T"]);
    writeFileSync(join(source, "s.txt"), "sub\n");
    git(source, ["add", "."]);
    git(source, ["commit", "-m", "sub"]);
    git(mount, ["-c", "protocol.file.allow=always", "submodule", "add", source, "sub"]);
    git(mount, ["commit", "-m", "add submodule"]);
    // The submodule is a repository the VM also controls: arm it, then dirty it.
    git(join(mount, "sub"), ["config", "core.fsmonitor", join(dirname(marker), "probe.sh")]);
    writeFileSync(join(mount, "sub", "s.txt"), "sob\n");
    const future = new Date(Date.now() + 5000);
    utimesSync(join(mount, "sub", "s.txt"), future, future);
    const trust = gitTrustForWorkspace(sandboxWorkspace(mount));
    // Setup ran under the armed config too; only the host calls below count.
    rmSync(marker, { force: true });

    const status = await getGitStatus(mount, trust);
    await getWorkspaceGitSummary(mount, trust);

    expect(status.isGitRepo).toBe(true);
    expect(markerLines(marker)).toEqual([]);
  });

  it("does not follow an untracked symlink to count host file lines", async () => {
    const { mount } = armedRepo();
    const outside = tempDir("oppi-git-safe-outside-");
    writeFileSync(join(outside, "host.txt"), "1\n2\n3\n4\n5\n");
    symlinkSync(join(outside, "host.txt"), join(mount, "leak.link"));

    const status = await getGitStatus(mount, gitTrustForWorkspace(sandboxWorkspace(mount)));

    const link = status.files.find((file) => file.path === "leak.link");
    expect(link).toMatchObject({ status: "??", addedLines: null });
  });
});

describe("sandbox git: confinement to the mount", () => {
  it("treats a gitfile pointing outside the mount as not a repository", async () => {
    const outside = armedRepo();
    const mount = tempDir("oppi-git-safe-mount-");
    writeFileSync(join(mount, ".git"), `gitdir: ${join(outside.mount, ".git")}\n`);
    const trust = gitTrustForWorkspace(sandboxWorkspace(mount));

    expect(isGitRepository(trust, mount)).toBe(false);
    await expect(getWorkspaceGitSummary(mount, trust)).resolves.toEqual({
      isGitRepo: false,
      changedCount: 0,
      ahead: null,
      behind: null,
    });
    expect((await getGitStatus(mount, trust)).isGitRepo).toBe(false);
    expect((await getCommitLog(mount, trust, 0, 10)).commits).toEqual([]);
    const result = await execGit(trust, mount, ["rev-parse", "HEAD"]);
    expect(result.error).toBeInstanceOf(SandboxGitRefusedError);
    expect(markerLines(outside.marker)).toEqual([]);
  });

  it("treats a .git symlink as not a repository", async () => {
    const outside = armedRepo();
    const mount = tempDir("oppi-git-safe-mount-");
    symlinkSync(join(outside.mount, ".git"), join(mount, ".git"));
    const trust = gitTrustForWorkspace(sandboxWorkspace(mount));

    expect(isGitRepository(trust, mount)).toBe(false);
    expect((await getGitStatus(mount, trust)).isGitRepo).toBe(false);
    expect(markerLines(outside.marker)).toEqual([]);
  });

  it("treats a relative gitfile that escapes through a symlink as not a repository", () => {
    const outside = armedRepo();
    const mount = tempDir("oppi-git-safe-mount-");
    symlinkSync(outside.mount, join(mount, "link"));
    writeFileSync(join(mount, ".git"), "gitdir: link/.git\n");

    expect(isGitRepository(gitTrustForWorkspace(sandboxWorkspace(mount)), mount)).toBe(false);
  });

  it("refuses when the object store is redirected outside the mount", async () => {
    const { mount } = armedRepo();
    const outside = tempDir("oppi-git-safe-outside-");
    writeFileSync(join(mount, ".git", "objects", "info", "alternates"), `${outside}\n`);
    const trust = gitTrustForWorkspace(sandboxWorkspace(mount));

    expect(isGitRepository(trust, mount)).toBe(false);
  });

  it("accepts a gitfile whose git dir stays inside the mount", async () => {
    const mount = tempDir("oppi-git-safe-mount-");
    git(mount, ["init", "--initial-branch=main", "--separate-git-dir", join(mount, ".gitdata")]);
    git(mount, ["config", "user.email", "t@example.invalid"]);
    git(mount, ["config", "user.name", "T"]);
    writeFileSync(join(mount, "a.txt"), "x\n");
    git(mount, ["add", "a.txt"]);
    git(mount, ["commit", "-m", "init"]);
    const trust = gitTrustForWorkspace(sandboxWorkspace(mount));

    expect(isGitRepository(trust, mount)).toBe(true);
    expect(await getGitStatus(mount, trust)).toMatchObject({ isGitRepo: true, branch: "main" });
  });

  it("refuses a worktree checkout whose gitfile belongs to another repository", async () => {
    const { mount } = armedRepo();
    const other = armedRepo();
    const checkout = tempDir("oppi-git-safe-checkout-");
    git(other.mount, ["worktree", "add", join(checkout, "wt"), "feature"]);
    const trust = gitTrustForWorkspace(sandboxWorkspace(mount));

    const result = await execGit(trust, join(checkout, "wt"), ["status", "--porcelain"]);

    expect(result.error).toBeInstanceOf(SandboxGitRefusedError);
  });

  it("refuses every command for a sandbox workspace without a mount", async () => {
    const trust = gitTrustForWorkspace({ runtime: "sandbox", hostMount: undefined });
    const dir = tempDir("oppi-git-safe-nomount-");
    git(dir, ["init", "--initial-branch=main"]);

    expect(isGitRepository(trust, dir)).toBe(false);
  });
});
